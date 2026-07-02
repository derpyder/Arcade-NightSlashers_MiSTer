@ Night Slashers — a23 (ARM) bring-up test program (M2a).
@ ARMv2a basic instructions only (valid on Amber a23). Loaded at 0x0.
@ Proves: ALU, STR/LDR to work RAM (0x100000), and a soundlatch write (0x200700).
    .arch armv2a
    .text
    .global _start
_start:
reset:
    mov     r0, #0x12          @ r0 = 0x12
    mov     r1, #0x34          @ r1 = 0x34
    add     r2, r0, r1         @ r2 = 0x46
    mov     r3, #0x100000      @ r3 = work-RAM base
    str     r2, [r3]           @ RAM[0x100000] = 0x46
    ldr     r4, [r3]           @ r4 = RAM[0x100000]   (load-back)
    add     r4, r4, #1         @ r4 = 0x47            (prove the load returned 0x46)
    str     r4, [r3, #4]       @ RAM[0x100004] = 0x47
    mov     r5, #0x200000      @ r5 = prot base
    orr     r5, r5, #0x700     @ r5 = 0x200700        (104 soundlatch port)
    mov     r6, #0x42          @ sound command
    mov     r6, r6, lsl #16    @ r6 = 0x00420000      (command in bits[23:16], MAME data>>16)
    str     r6, [r5]           @ snd_latch <= 0x42, snd_req pulse
loop:
    b       loop               @ spin
