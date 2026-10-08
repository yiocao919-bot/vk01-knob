#!/usr/bin/env python3
"""VK-01 / ANTICATER_MINI USB 配置小工具（需要先 python3 -m pip install --user hidapi）。
用法:
  python3 ~/anticater_debug/vk01.py list      # 列出接口并发送"读取配置"请求（不改设置）
  python3 ~/anticater_debug/vk01.py set a     # 把旋钮按下设成 A
  python3 ~/anticater_debug/vk01.py set f13   # 把旋钮按下设成 F13
  python3 ~/anticater_debug/vk01.py light ff0000 [亮度0-100]   # 灯光颜色
  python3 ~/anticater_debug/vk01.py light off
"""
import sys, time, os

VID, PID = 0x514C, 0x8850
LOG = os.path.expanduser("~/anticater_debug/vk01_out.txt")
KEYS = {"a": 0x04, "f13": 0x68, "f14": 0x69, "f15": 0x6A}

out = open(LOG, "a")
def say(*a):
    s = " ".join(str(x) for x in a)
    print(s); out.write(s + "\n"); out.flush()

import hid  # pip 包 hidapi

def hx(b): return " ".join(f"{x:02X}" for x in b)

def interfaces():
    res = []
    for i in hid.enumerate(VID, PID):
        res.append(dict(path=i["path"], page=i.get("usage_page", 0), usage=i.get("usage", 0),
                        iface=i.get("interface_number", -1), bus=i.get("bus_type", "?"),
                        product=i.get("product_string")))
    return res

def pkt(*head):
    b = bytes(head); return b + bytes(65 - len(b))

def talk(path, packets, listen=1.5):
    d = hid.device()
    try:
        d.open_path(path)
    except Exception as e:
        say("   打开失败:", e); return None
    got = []
    try:
        for p in packets:
            try:
                n = d.write(list(p))
                say(f"   写入 {len(p)} 字节 -> 返回 {n}")
            except Exception as e:
                say("   写入失败:", e)
            time.sleep(0.06)
        end = time.time() + listen
        while time.time() < end:
            r = d.read(65, 200)
            if r:
                got.append(bytes(r)); say("   收到:", hx(r))
    finally:
        d.close()
    return got

def main():
    say("=====", time.strftime("%H:%M:%S"), " ".join(sys.argv[1:]))
    ifs = interfaces()
    if not ifs:
        say("没找到 514C:8850。请确认 USB 线插着，且是数据线。"); sys.exit(2)
    for i in ifs:
        say(f"接口 iface={i['iface']} usagePage=0x{i['page']:04X} usage=0x{i['usage']:04X} bus={i['bus']} {i['product']}")
    vendor = [i for i in ifs if i["page"] >= 0xFF00] or ifs
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        q = bytes([0x03] + [0xFF] * 64)
        for i in vendor:
            say(f"-> 向 iface={i['iface']} page=0x{i['page']:04X} 发送读取配置请求")
            talk(i["path"], [q])
    elif cmd == "set":
        k = KEYS[sys.argv[2].lower()]
        p1 = pkt(0x03, 0xFD, 0x03, 0x01, 0x01, 0x00, 0x01, 0x00, 0x00, k)
        p2 = pkt(0x03, 0xFD, 0xFE, 0xFF)
        for i in vendor:
            say(f"-> 向 iface={i['iface']} page=0x{i['page']:04X} 写入: 按下 = {sys.argv[2]}")
            if talk(i["path"], [p1, p2]) is not None:
                break
        else:
            sys.exit(3)
    elif cmd == "light":
        # 灯光包（从配置程序反汇编得到）: 03 FD 00 06 R G B 亮度(0-100) 开关
        c = sys.argv[2].lstrip("#")
        if c == "off":
            r = g = b = 0; on = 0
        else:
            r, g, b = int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16); on = 1
        br = int(sys.argv[3]) if len(sys.argv) > 3 else 100
        p = pkt(0x03, 0xFD, 0x00, 0x06, r, g, b, max(0, min(100, br)), on)
        for i in vendor:
            say(f"-> 灯光 {c} 亮度 {br}")
            if talk(i["path"], [p, pkt(0x03, 0xFD, 0xFE, 0xFF)], listen=0.3) is not None:
                break
        else:
            sys.exit(3)
    elif cmd == "lightkey":
        # 灯光功能键包（反汇编 sendLightKey）: 03 FE B0 <序号0/1/2> <功能0-5> + 16色色表，共发3包
        idx = int(sys.argv[2])
        pal = bytes.fromhex("ff0000ff8030ffff3000ff0000ffff0000ff800080 8b0000ffa500ffff967dff00008b8b00008bff00ffff6666ffc864".replace(" ",""))
        pkts = []
        for seq in (0, 1, 2):
            head = bytes([0x03, 0xFE, 0xB0, seq, idx]) + pal
            pkts.append(head + bytes(65 - len(head)))
        pkts.append(pkt(0x03, 0xFD, 0xFE, 0xFF))
        for i in vendor:
            say(f"-> 灯光功能键 {idx}")
            if talk(i["path"], pkts, listen=0.3) is not None:
                break
    elif cmd == "led":
        # 灯效模式包: 03 FE B0 <层0/1/2> <模式> + 48字节色表。模式 0关 1红 2绿 3涟漪 4彩虹 5RGB
        # 用法: led 模式 [RRGGBB]   例: led 1  /  led 5 0000ff
        mode = int(sys.argv[2])
        if len(sys.argv) > 3:
            c = sys.argv[3].lstrip("#")
            pal = bytes.fromhex(c[0:6]) * 16
        else:
            pal = bytes.fromhex("ff0000ff8030ffff3000ff0000ffff0000ff8000808b0000ffa500ffff967dff00008b8b00008bff00ffff6666ffc864")
        pkts = []
        for layer in (0, 1, 2):
            m = mode if layer == 0 else 0
            head = bytes([0x03, 0xFE, 0xB0, layer, m]) + pal
            pkts.append(head + bytes(65 - len(head)))
        pkts.append(pkt(0x03, 0xFE, 0xFF))
        pkts.append(pkt(0x03, 0xFD, 0xFE, 0xFF))   # 按键设置用的保存包，灯光也补发一次
        for i in vendor:
            say(f"-> 灯效模式 {mode}" + (f" 色表 {sys.argv[3]}" if len(sys.argv) > 3 else ""))
            if talk(i["path"], pkts, listen=0.5) is not None:
                break
        else:
            sys.exit(3)
    elif cmd == "ledget":
        # 读取灯效: 03 FA B0 <层>
        for i in vendor:
            say("-> 读取灯效")
            if talk(i["path"], [pkt(0x03, 0xFA, 0xB0, l) for l in (0, 1, 2)], listen=1.0) is not None:
                break
        else:
            sys.exit(3)
    say("完成。结果也保存在", LOG)

main()
