import torch
from .simulator import nv_ptx, mx
from .experiments import rounding

def check_tensor(A: torch.Tensor, B: torch.Tensor) -> None:
    assert A.shape == B.shape, "Shape mismatch"
    assert A.dtype == torch.float32
    assert B.dtype == torch.float32

    A_flat = A.detach().reshape(-1)
    B_flat = B.detach().reshape(-1)
    n = A_flat.numel()

    all_equal = True
    for idx in range(n):
        a_hex = A_flat.view(torch.int32)[idx].item()
        b_hex = B_flat.view(torch.int32)[idx].item()
        if a_hex != b_hex:
            all_equal = False
            print(f"Mismatch at index {idx}")
            print(f"sw hex = 0x{a_hex & 0xFFFFFFFF:08X}")
            print(f"hw hex = 0x{b_hex & 0xFFFFFFFF:08X}")
            print()

    if all_equal:
        print("All elements are bitwise identical.")

def blackwell():
    arch = "Blackwell"
    qualifier = "m16n8k16.f32.f16.f16.f32"
    op = nv_ptx.mma(arch, qualifier)

    m, n, k = op.m, op.n, op.k
    A = torch.randn(m, k, dtype=op.a_type)
    B = torch.randn(k, n, dtype=op.b_type)
    C = torch.randn(m, n, dtype=op.c_type)

    D = op(A, B, C)

    A_c = A.to(torch.device("cuda"))
    B_c = B.to(torch.device("cuda"))
    C_c = C.to(torch.device("cuda"))
    D_c = D.to(torch.device("cuda"))

    B_pad = torch.zeros((16, 16), dtype=B_c.dtype, device="cuda")
    B_pad[:, :n] = B_c
    B_col = B_pad.t().contiguous()

    C_pad = torch.zeros((16, 16), dtype=C_c.dtype, device="cuda")
    C_pad[:, :n] = C_c

    from .hw.nv import wmma_ext
    ref_16 = wmma_ext.wmma_gemm(A_c, B_col, C_pad)
    ref = ref_16[:, :n]

    torch.cuda.synchronize()
    check_tensor(D_c, ref)

def mx_c500():
    arch = "Ampere"
    qualifier = "m16n8k16.f32.f16.f16.f32"
    op = mx.mma(arch, qualifier)

    m, n, k = op.m, op.n, op.k
    A = torch.randn(m, k, dtype=op.a_type)
    B = torch.randn(k, n, dtype=op.b_type)
    C = torch.randn(m, n, dtype=op.c_type)

    D = op(A, B, C)

    A_c = A.to(torch.device("cuda"))
    B_c = B.to(torch.device("cuda"))
    C_c = C.to(torch.device("cuda"))
    D_c = D.to(torch.device("cuda"))

    B_pad = torch.zeros((16, 16), dtype=B_c.dtype, device="cuda")
    B_pad[:, :n] = B_c
    B_col = B_pad.t().contiguous()

    C_pad = torch.zeros((16, 16), dtype=C_c.dtype, device="cuda")
    C_pad[:, :n] = C_c

    from .hw.mx import wmma_ext_maca
    ref_16 = wmma_ext_maca.wmma_gemm(A_c, B_col, C_pad)
    ref = ref_16[:, :n]

    torch.cuda.synchronize()
    check_tensor(D_c, ref)

def mx_c500_accum_precision_test():
    arch = "Ampere"
    qualifier = "m16n8k16.f32.f16.f16.f32"
    op = mx.mma(arch, qualifier)

    m, n, k = 16, 16, 16

    A = torch.zeros((m, k), dtype=op.a_type, device="cuda")
    B = torch.zeros((k, n), dtype=op.b_type, device="cuda")
    C = torch.zeros((m, n), dtype=op.c_type, device="cuda")

    eps = 2.0**-24
    A[0, 0] = eps
    B[0, 0] = eps
    A[0, 1] = eps

    for t in range(0, 100):
        # p2 = eps
        # eps0 = 2.0**-24 if t > 24 else 2.0**-t
        # eps1 = 2.0**-(t-24) if t > 24 else 1.0

        eps_dyn = 2.0**-(24-t)
        B[1, 0] = eps_dyn

        B_col = B.t().contiguous()

        from .hw.mx import wmma_ext_maca
        D = wmma_ext_maca.wmma_gemm(A, B_col, C)

        got = D.view(torch.uint32)[0, 0].item()
        expect_hex = torch.tensor(eps*eps+eps*eps_dyn , dtype=torch.float32).view(torch.uint32).item()
        eps_dyn_hex = torch.tensor(eps_dyn, dtype=torch.float32).view(torch.uint32).item()
        if got != expect_hex:
            print(f"Mismatch at t = {t}")
            print(f"got = 0x{got & 0xFFFFFFFF:08X}")
            print(f"expect = 0x{expect_hex & 0xFFFFFFFF:08X}")
            print(f"eps_dny = 0x{eps_dyn_hex & 0xFFFFFFFF:08X}")
            break

def mx_c500_accum_precision_test1():
    arch = "Ampere"
    qualifier = "m16n8k16.f32.f16.f16.f32"
    op = mx.mma(arch, qualifier)

    m, n, k = 16, 16, 16

    A = torch.zeros((m, k), dtype=op.a_type, device="cuda")
    B = torch.zeros((k, n), dtype=op.b_type, device="cuda")
    C = torch.zeros((m, n), dtype=op.c_type, device="cuda")

    A[0, 0] = 1.0
    B[0, 0] = 1.0
    B[1, 0] = 1.0
    B_col = B.t().contiguous()

    for t in range(0, 100):
        # p2 = eps
        # eps0 = 2.0**-24 if t > 24 else 2.0**-t
        # eps1 = 2.0**-(t-24) if t > 24 else 1.0

        eps_dyn = 2.0**t
        A[0, 1] = eps_dyn

        from .hw.mx import wmma_ext_maca
        D = wmma_ext_maca.wmma_gemm(A, B_col, C)

        got = D.view(torch.uint32)[0, 0].item()
        expect_hex = torch.tensor(1.0+eps_dyn , dtype=torch.float32).view(torch.uint32).item()
        eps_dyn_hex = torch.tensor(eps_dyn, dtype=torch.float32).view(torch.uint32).item()
        print(f"Mismatch at t = {t}")
        print(f"got = 0x{got & 0xFFFFFFFF:08X}")
        print(f"expect = 0x{expect_hex & 0xFFFFFFFF:08X}")
        print(f"eps_dny = 0x{eps_dyn_hex & 0xFFFFFFFF:08X}")
        if got != expect_hex:
            print(f"Mismatch at t = {t}")
            print(f"got = 0x{got & 0xFFFFFFFF:08X}")
            print(f"expect = 0x{expect_hex & 0xFFFFFFFF:08X}")
            print(f"eps_dny = 0x{eps_dyn_hex & 0xFFFFFFFF:08X}")
            break

def test():
    m, n, k = 16, 16, 16

    A = torch.zeros((m, k), dtype=torch.float16, device="cuda")
    B = torch.zeros((k, n), dtype=torch.float16, device="cuda")
    C = torch.zeros((m, n), dtype=torch.float32, device="cuda")

    # p0 = -1.0
    A[0, 0] = torch.tensor(-65504.0, dtype=torch.float16, device="cuda")
    B[0, 0] = torch.tensor(1.0, dtype=torch.float16, device="cuda")

    # # p1 = +1.0
    A[0, 1] = torch.tensor(65504.0, dtype=torch.float16, device="cuda")
    B[1, 0] = torch.tensor(1.0, dtype=torch.float16, device="cuda")

    # A[0, 2] = 0.125
    # B[2, 0] = 1.0

    B_col = B.t().contiguous()

    from .hw.mx import wmma_ext_maca
    D = wmma_ext_maca.wmma_gemm(A, B_col, C)

    got = D.view(torch.uint32)[0, 0].item()
    print(f"-65504 + 65504 = 0x{got & 0xFFFFFFFF:08X}")

    # p0 = -1.0
    A[0, 0] = torch.tensor(-1.0, dtype=torch.float16, device="cuda")
    B[0, 0] = torch.tensor(1.0, dtype=torch.float16, device="cuda")

    # # p1 = +1.0
    A[0, 1] = torch.tensor(1.0, dtype=torch.float16, device="cuda")
    B[1, 0] = torch.tensor(1.0, dtype=torch.float16, device="cuda")

    B_col = B.t().contiguous()

    from .hw.mx import wmma_ext_maca
    D = wmma_ext_maca.wmma_gemm(A, B_col, C)

    got = D.view(torch.uint32)[0, 0].item()
    print(f"-1 + 1 = 0x{got & 0xFFFFFFFF:08X}")



if __name__ == "__main__":
    #blackwell()
    # mx_c500_accum_precision_test()
    rounding.detect()
