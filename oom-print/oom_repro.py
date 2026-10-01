#!/usr/bin/env python3
import torch
import math

TARGET_GIB = 140
CHUNK_GIB = 1        # used if single-shot allocation fails
DEVICE = "cuda:0"

def gib(n_bytes: int) -> float:
    return n_bytes / (1024 ** 3)

def print_mem(prefix=""):
    free_b, total_b = torch.cuda.mem_get_info(device=DEVICE)
    reserved = torch.cuda.memory_reserved(device=DEVICE)
    allocated = torch.cuda.memory_allocated(device=DEVICE)
    print(f"{prefix}GPU total: {gib(total_b):.2f} GiB | free: {gib(free_b):.2f} GiB "
          f"| reserved: {gib(reserved):.2f} GiB | allocated: {gib(allocated):.2f} GiB")

def main():
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is not available. Check your PyTorch/CUDA install.")

    torch.cuda.set_device(DEVICE)
    print_mem("[before] ")

    target_bytes = TARGET_GIB * (1024 ** 3)

    # Try a single big allocation with uint8 so 1 element = 1 byte.
    try:
        print(f"Attempting single allocation of {TARGET_GIB} GiB on {DEVICE}…")
        big = torch.empty(target_bytes, dtype=torch.uint8, device=DEVICE)
        torch.cuda.synchronize()
        print("Success (single allocation).")
        print_mem("[after ] ")
        input("Holding allocation. Press Enter to free and exit…")
        del big
        torch.cuda.synchronize()
        print_mem("[freed ] ")
        return
    except RuntimeError as e:
        print(f"Single allocation failed: {e}\nFalling back to {CHUNK_GIB} GiB chunks…")

    # Chunked fallback
    chunk_bytes = CHUNK_GIB * (1024 ** 3)
    num_chunks = math.ceil(target_bytes / chunk_bytes)
    blocks = []
    allocated_bytes = 0

    for i in range(num_chunks):
        try:
            blk = torch.empty(chunk_bytes, dtype=torch.uint8, device=DEVICE)
            blocks.append(blk)
            allocated_bytes += chunk_bytes
            print_mem(f"[chunk {i+1}/{num_chunks}] ")
        except RuntimeError as e:
            print(f"Chunk {i+1} failed: {e}")
            break

    print(f"Allocated ~{gib(allocated_bytes):.2f} GiB in {len(blocks)} chunk(s).")
    print_mem("[final ] ")
    input("Holding allocation. Press Enter to free and exit…")
    del blocks
    torch.cuda.synchronize()
    print_mem("[freed ] ")

if __name__ == "__main__":
    main()

