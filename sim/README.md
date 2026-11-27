# DEPTH regression kit

สองชุด ใช้ยืนยันว่าแก้ RTL แล้วภาพและ gameplay ไม่เพี้ยน

| ไฟล์ | ใช้ทำอะไร |
|---|---|
| `harness.cpp` | จำลองทั้งชิปด้วย Verilator แล้ว "ดู" ขา `VGA_*` แบบจอมอนิเตอร์จริง (ล็อกกับ HS/VS เท่านั้น) เขียนภาพออกมาเป็น PPM 640×480 — latency ที่เพิ่มใน pipeline จึงมองไม่เห็น ตราบใดที่ sync เลื่อนตามกัน |
| `logharness.cpp` | กดปุ่มตามสคริปต์ 120 เฟรม แล้ว dump state ทุกเฟรม (ตำแหน่งผู้เล่น, โดรน, โซนาร์, LED, 7-seg, นาฬิกา) |
| `sonar_model.py` | โมเดลอ้างอิงของ `radar_1d` เขียนจากอัลกอริทึมตรง ๆ ใช้เช็กว่า RTL วัดระยะถูก |
| `compare_frames.py` | เทียบ PPM สองชุดทีละพิกเซล |
| `tb_capture.v`, `tb_logic.v` | testbench แบบเดียวกันสำหรับ Icarus Verilog (ช้ากว่ามาก ใช้ตอนไม่มี Verilator) |

## รัน

```
./run_regression.sh                       # เรนเดอร์ภาพ + log + เช็กโซนาร์
./run_regression.sh ../../Group17_DEPTH_timingfix   # เทียบกับเวอร์ชันเก่าด้วย
```

ต้องมี `verilator`, `g++`, `python3`
(Ubuntu/WSL: `sudo apt install verilator build-essential python3`)

ผลที่คาดไว้เมื่อเทียบกับ board export เดิม:
* `A_title B_echo C_map F_sight3 G_echo_walk J_map_clean` → **IDENTICAL**
* `D_sight E_sight2 H_sight_clean I_sight_clean2` → ต่างเฉพาะการเลื่อน 1 พิกเซล (residual 0)
  ซึ่งคือการแก้บั๊กที่ภาพ 3D เคยไม่ตรงกับ HUD และ sync
* logic log → ต่างเฉพาะระยะโซนาร์ (`df/dl/dr`) และ `LED/seg` ที่แสดงค่านั้น

ถ้า Icarus: ดู `tb_capture.v` — คอมไพล์ด้วย
`iverilog -g2005 -I../src -D DEBOUNCE_CYCLES=50 -D PRESS_CYCLES=400 -o sim.vvp tb_capture.v ../src/*.v`
(ต้องคัดลอก `../mem/*.mem` มาไว้ใน cwd ก่อน)
