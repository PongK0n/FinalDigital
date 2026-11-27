# DEPTH — Nexys A7-100T (v2, timing-closed)

เวอร์ชันนี้แก้ปัญหาที่ build เดิมหยุดที่ **TIMING/ROUTING GATE FAILED (WNS = −6.461 ns)**
และปรับสถาปัตยกรรมของบล็อกที่เป็นคอขวดใหม่ทั้งหมด โดยที่ **ภาพบนจอยังเหมือนเดิม**
(พิสูจน์ด้วย regression ระดับพิกเซล — ดูหัวข้อ *การตรวจสอบ* ด้านล่าง)

---

## วิธี Build

เปิด Vivado Tcl Shell / terminal ที่มี `vivado` ใน PATH แล้ว `cd` มาที่โฟลเดอร์นี้:

```
vivado -mode batch -source build.tcl
```

| คำสั่ง | ผลลัพธ์ |
|---|---|
| `vivado -mode batch -source build.tcl` | build เต็ม → `.bit`, `.bin`, `.mcs`, `reports/` |
| `... -source build.tcl -tclargs project` | สร้างโปรเจกต์อย่างเดียว แล้วเปิด `vivado/Group17_DEPTH.xpr` ใน GUI |
| `... -source build.tcl -tclargs clean` | ลบโปรเจกต์และไฟล์ที่ generate ออกทั้งหมด |

จาก GUI: `Tools → Run Tcl Script… → build.tcl`

> ❌ **อย่าสร้างโปรเจกต์เองด้วยมือ** — ถ้าลืม add ไฟล์ `.mem` ROM จะเป็น 0 ทั้งหมด
> (จอดำ/ไม่มีเสียง) โดย Vivado ไม่ error. `build.tcl` เช็กให้แล้วก่อนเริ่ม

---

## สาเหตุที่ build เดิมไม่ผ่าน

ปัญหาไม่ได้อยู่ที่จุดเดียว แต่เป็นรูปแบบเดียวกันที่เกิดซ้ำ 3 ที่:
**หน่วยความจำขนาดใหญ่ถูกอ่านแบบ asynchronous แล้วต่อ logic ยาวต่อท้ายภายใน clock เดียว**

| จุด | สิ่งที่อยู่ใน 1 clock (10 ns) ของเดิม |
|---|---|
| `tile_map` | ROM 1024 ช่อง อ่าน async **4 พอร์ตพร้อมกัน** → mux 1024:1 ลึก ~5 ระดับ ต่อพอร์ต |
| `raycaster_3d` scanout | mux 160:1 บน flip-flop 1,440 ตัว → ลบความสูงกำแพง → เทียบ texture 7 ชั้น (มีคูณค่าคงที่ 3 ตัว) → font ROM → เลือกสี |
| `topdown_2d` + `hud_sprite` + `render_mux` | `pixel_x/pixel_y` → hash → ที่อยู่ tile → ROM async → เลือกสี → mux → **ขาออกของชิป** ทั้งหมดเป็น combinational ก้อนเดียวข้าม 3 โมดูล |

ไฟล์ `.xdc` เดิมมี `set_multicycle_path 4` คร่อม register ขาออก VGA ซึ่ง
**ปิดบังปัญหาแทนที่จะแก้** และไม่ครอบคลุม `raycaster_3d` ที่เป็นจุดที่ timing พังจริง
— บรรทัดนั้นถูกลบออกแล้ว ตอนนี้ออกแบบผ่าน 100 MHz ตรง ๆ

---

## สิ่งที่เปลี่ยน

### 1. หน่วยความจำทั้งหมดเป็น block RAM อ่านแบบ synchronous
`rtl_prims.v` เพิ่ม `rom_sp` / `rom_dp` / `ram_sdp` / `pix_delay`

* `tile_map` → block ROM 2 ตัว (dual-port) ให้ครบ 4 พอร์ตอ่าน + fog bitmap ย้ายจาก
  flip-flop 1,024 ตัวไปเป็น block RAM พร้อม write engine เล็ก ๆ (เคลียร์ 1024 คล็อก /
  เปิดหมอก 5×5 = 25 คล็อก ทำในช่วง vblank ~144,000 คล็อก)
* LUT ของ sin / cos / 1-over-d และ sprite ROM → block ROM อ่านแบบมี register
* column buffer ของ raycaster (160 × 18 บิต) → block RAM แทน flip-flop 1,440 ตัว
  (ลูป reset 160 ช่องก็หายไปด้วย — ตัวนี้ทำให้ Verilator compile ไม่ผ่านด้วยซ้ำ)

ผู้ใช้พอร์ตทุกตัวถูกปรับจังหวะให้รองรับ latency 1 คล็อก โดยผลลัพธ์เท่าเดิมทุกบิต

### 2. ท่อภาพ (video pipeline) ความลึกเท่ากันทุกตัว
renderer ทุกตัว (`topdown_2d`, `raycaster_3d`, `hud_sprite`, แบนเนอร์ใน `render_mux`)
ส่งสีของพิกเซล N ออกมาช้ากว่า `vga_sync` เท่ากันพอดี **`PIPE_STAGES` = 6 pixel-clock**
และ `top_depth` หน่วง `HS/VS/DE` เท่ากัน → จอเห็นภาพ 640×480\@60 เหมือนเดิมทุกประการ
(`depth_pkg.vh` เก็บค่านี้ไว้ที่เดียว)

### 3. ย้ายงานที่คงที่ทั้งเฟรมออกจาก pixel path
ตำแหน่งผู้เล่น/โดรนบนจอ, จุดชี้ทิศ, การอ่าน sin/cos — เดิมคำนวณใหม่ **ทุกพิกเซล**
(ตัวคูณ 16 บิต 8 ตัว + LUT 2 ตัว) ตอนนี้ latch ครั้งเดียวตอน vblank

### 4. บั๊กที่แก้ไปด้วย

| บั๊ก | อาการเดิม |
|---|---|
| ภาพ 3D เลื่อนไป 1 พิกเซล | `rgb_3d` ถูก register แต่ `rgb_2d`/HUD/ไตเติลเป็น combinational → ใน SIGHT ภาพ 3 มิติอยู่ขวากว่า HUD และ sync 1 พิกเซล และพิกเซลแรกของทุกบรรทัดเป็นสีดำ |
| raycaster เฉือน (shear) | 160 คอลัมน์อ่าน `player_x/_y/_angle` ใหม่ทีละคอลัมน์ ขณะที่ `player_state` ยังอัปเดตอยู่ → ตอนเดินภาพบิดที่ขอบซ้าย ตอนนี้ snapshot ท่าผู้เล่นครั้งเดียวต่อเฟรม |
| โซนาร์วัดผิด | `radar_1d` ยิง 4 เส้นจากตำแหน่งผู้เล่น **คนละตำแหน่ง** ภายในเฟรมเดียว (ray 0 ใช้ค่าเก่า, ray 1–3 ใช้ค่าใหม่) → ระยะหน้า/ซ้าย/ขวาไม่สอดคล้องกัน มีผลต่อ LED, 7-segment และเสียง ping. ตรวจกับโมเดลอ้างอิงแล้ว: ของเดิมผิด 35 จาก 109 เฟรม, ของใหม่ถูก 109 จาก 109 |

### 5. ภาพ 3D สวยขึ้น (`DEPTH_SHADING`, เปิดไว้เป็นค่าเริ่มต้น)
* **แรเงาตามระยะ** — กำแพงไกลมืดลงเป็น 4 ระดับ (คำนวณจากความสูงคอลัมน์ ใช้แค่ shift + add ไม่กิน DSP)
* **ไล่เฉดพื้น/เพดาน** พร้อม 2×2 ordered dither เพื่อไม่ให้เห็นเป็นแถบ

ปิดได้ด้วย `top_depth #(.DEPTH_SHADING(0))` แล้วภาพจะกลับไปเหมือน build เดิมทุกบิต
(regression ใช้โหมดนี้ยืนยัน)

### 6. `build.tcl` และ `.xdc`
* เช็กไฟล์ `.mem` ครบก่อนเริ่ม — กันเคส "จอดำแต่ Vivado ไม่ error"
* รายงาน timing หลัง synthesis ด้วย ไม่ต้องรอจนจบ implementation
* **ถ้า timing ไม่ผ่าน จะ retry อัตโนมัติ 1 ครั้ง** ด้วย `Flow_PerfOptimized_high` +
  `Performance_ExplorePostRoutePhysOpt` ก่อนยอมแพ้
* สรุป WNS / WHS / การใช้ทรัพยากร ออกหน้าจอ
* สร้าง `.mcs` สำหรับ Quad-SPI flash → **บอร์ดบูตเกมเองได้โดยไม่ต้องต่อคอม**
* `.xdc`: ลบ multicycle hack, เพิ่ม `set_false_path` ให้ I/O ที่เป็น asynchronous จริง,
  ตั้งค่า bitstream (SPIx4, compress)

---

## การตรวจสอบ (ทำแล้ว ก่อนส่ง)

`sim/` มีชุดทดสอบที่ใช้จริง รันซ้ำได้เอง (ต้องมี `verilator` + `g++`)

```
cd sim && ./run_regression.sh
```

1. **Pixel regression** — จำลองทั้งชิปแล้วจับภาพจากขา `VGA_*` แบบเดียวกับจอมอนิเตอร์จริง
   (ล็อกกับ HS/VS เท่านั้น จึงไม่สนใจ latency ที่เพิ่มเข้ามา) เทียบ 10 เฟรม
   (TITLE / ECHO / MAP / SIGHT 4 มุม / เดินชนกำแพง) ระหว่างของเดิมกับของใหม่
   → **7 เฟรมตรงกันทุกบิต**, อีก 3 เฟรม (SIGHT) ต่างกันเฉพาะการเลื่อน 1 พิกเซลที่เป็นการแก้บั๊ก
   (เหลือ residual = 0)
2. **Logic regression** — สคริปต์กดปุ่ม 120 เฟรม เทียบ state ทุกเฟรม
   → `px py pa` (ตำแหน่ง/มุมผู้เล่น), โดรน, game state, นาฬิกา, ธง lens, ประตู, jamming
   **ตรงกันทุกเฟรม**; ต่างเฉพาะระยะโซนาร์ซึ่งเป็นการแก้บั๊กข้างบน
3. **Sonar reference model** — เขียนโมเดลอ้างอิงด้วย Python จากอัลกอริทึม (ไม่ได้ดูจาก RTL)
   → ของใหม่ตรง 109/109 เฟรม, ของเดิมผิด 35/109

---

## Program บอร์ด

1. เสียบ USB (PROG/UART), เปิดสวิตช์ POWER, เสียบจอ VGA (+ หูฟังถ้าต้องการเสียง)
2. Vivado → `Open Hardware Manager` → `Open Target` → `Auto Connect`
3. `Program Device` → เลือก `Group17_DEPTH.bit` → `Program`

ลงแฟลชถาวร (บอร์ดบูตเองตอนเปิดเครื่อง):
`Add Configuration Memory Device` → `s25fl128sxxxxxx0-spi-x1_x2_x4` → `Group17_DEPTH.mcs`

## Checklist ทดสอบบนบอร์ด

| # | ทดสอบ | คาดหวัง |
|---|---|---|
| 1 | หลัง program | จอขึ้นหน้า TITLE "DEPTH" ไม่กระพริบ/ไม่ขึ้น Out of Range |
| 2 | กดปุ่มใดก็ได้ | เข้า PLAY (ECHO) — 7-seg ขวาเริ่มนับเวลา MM:SS |
| 3 | BTNU/BTND/BTNL/BTNR | เดิน/หมุน, LED ซ้าย-ขวาเปลี่ยนตามระยะกำแพง, เสียง ping เปลี่ยน |
| 4 | กด CPU_RESET | กลับหน้า TITLE |
| 5 | เก็บ Lens 1 → SW15:14 = `01` | เข้า MAP |
| 6 | เก็บ Lens 2 → SW15:14 = `10` | เข้า SIGHT (3D) — กำแพงไกลควรมืดกว่ากำแพงใกล้ |
| 7 | หน้าประตู: SW3–SW0 + BTNC | ใส่รหัส 4 หลักบน 7-seg ซ้าย |

## โครงสร้าง

| โฟลเดอร์/ไฟล์ | เนื้อหา |
|---|---|
| `src/` | Verilog RTL (top = `top_depth`) |
| `src/rtl_prims.v` | block RAM/ROM + pixel delay primitives ที่ใช้ร่วมกัน |
| `src/depth_pkg.vh` | ค่าคงที่ร่วม + `PIPE_STAGES` |
| `mem/` | ROM init (`sin/cos/inv_lut`, `tile_map`, `hud_sprites`, `wave_rom`) |
| `constraints/` | `nexys_a7_100t.xdc` |
| `sim/` | ชุด regression (Verilator + Icarus) |
| `build.tcl` | สร้างโปรเจกต์ + build ทั้งหมดในคำสั่งเดียว |
