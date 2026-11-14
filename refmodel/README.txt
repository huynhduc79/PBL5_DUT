BO VECTOR KIEM THU GOLDEN CHO RTL (xem manifest.json de biet phien ban, hash cau hinh, bo cuc)

CSV: dong dau la ten cot. Cot so in dang hex chu thuong du so 0 dau (do rong = ceil(bit / 4));
     cot chu (case, key_hex, frame...) in nguyen van. Khong co dau phay trong o.
HEX: moi dong = mot tu rong gom cac cot SO cua dong CSV tuong ung, cot dau tien o bit cao nhat.
     Bo cuc (ten cot, so bit) nam trong manifest.json -> tables.<ten>.layout.
Quy uoc: bit 0 = LSB; hoan vi pi dong thanh so: nibble i = pi[i] (pi[0] o nibble thap nhat);
     ma hoa: C = gather(P, pi) XOR k  (gather: bit i cua ket qua = bit pi[i] cua P);
     giai ma: dua C vao, ky vong P (cung bang, doc nguoc cot c -> p).
Trace (trace_<bo>.txt): moi dong '<so_mau>,<TEN_SU_KIEN>,<truong>...' (xem refmodel/compare.py);
     so sanh log RTL voi golden bang:  python -m refmodel.compare trace trace_<bo>.txt log_rtl.txt
Kiem tra bo vector con nguyen ven / golden chua doi:  python -m refmodel.gen_vectors --check <thu_muc>
