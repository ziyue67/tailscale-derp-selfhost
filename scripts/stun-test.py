import socket, struct, os, time, sys
host = sys.argv[1] if len(sys.argv) > 1 else '43.128.21.208'
port = int(sys.argv[2]) if len(sys.argv) > 2 else 3478
tid = os.urandom(12)
pkt = struct.pack('>HHI12s', 0x0001, 0, 0x2112A442, tid)
for attempt in range(3):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(5)
        t0 = time.time()
        s.sendto(pkt, (host, port))
        data, addr = s.recvfrom(2048)
        dt = (time.time()-t0)*1000
        print(f"  ✅ STUN {host}:{port} 响应 {len(data)} 字节, {dt:.0f}ms")
        # 解析 XOR-MAPPED-ADDRESS
        if len(data) > 20:
            mtype, mlen = struct.unpack('>HH', data[0:4])
            print(f"     类型=0x{mtype:04x} 长度={mlen}")
            off = 20
            while off + 4 <= len(data):
                atype, alen = struct.unpack('>HH', data[off:off+4])
                if atype == 0x0020 and alen >= 8:
                    fam = data[off+5]
                    p = struct.unpack('>H', data[off+6:off+8])[0] ^ 0x2112
                    ip = bytes(b ^ k for b, k in zip(data[off+8:off+12], struct.pack('>I', 0x2112A442)))
                    print(f"     XOR-MAPPED: {socket.inet_ntoa(ip)}:{p}")
                off += 4 + alen + ((4 - alen % 4) % 4)
        s.close()
        sys.exit(0)
    except socket.timeout:
        print(f"  ❌ 第{attempt+1}次: 超时")
    except Exception as e:
        print(f"  ❌ 第{attempt+1}次: {e}")
sys.exit(1)
