#!/usr/bin/env python3
"""Render the mmu_sv32 circuit / datapath diagram to docs/mmu_sv32_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, NOT a simulator
capture): the virtual-address split, the fully-associative TLB CAM with its
per-entry vpn comparators feeding the hit-OR and the entry mux, the megapage
PPN splice, the permission-check block driven by the CSR state, the bare/M-mode
bypass mux on the response path, and below it the page-table walker - the
walk_base / walk_level registers, the PTE address former
{walk_base, vpn[level], 2'b00}, the PTE decoder that classifies each PTE as
invalid / pointer / leaf, and the install path with its invalid-first +
round-robin victim selector. Insets give the Sv32 PTE bit layout, the walk
algorithm and the permission equations the RTL implements.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

CPU_C = "#0369a1"   # CPU-side port
CSR_C = "#0f766e"   # CSR / mode state
TLB_C = "#7c3aed"   # TLB storage
CMP_C = "#16a34a"   # comparators / hit logic
PRM_C = "#be185d"   # permission check
FSM_C = "#b45309"   # walker FSM
PTW_C = "#2563eb"   # walk memory port
RSP_C = "#4338ca"   # response path
FLT_C = "#dc2626"   # fault path
INK   = "#1f2937"
MUT   = "#6b7280"
GRID  = "#e5e7eb"

fig, ax = plt.subplots(figsize=(18.5, 12.0))
ax.set_xlim(0, 186)
ax.set_ylim(0, 121)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=9.2, lw=1.9, z=3):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.4,rounding_size=1.6",
                 linewidth=lw, edgecolor=ec, facecolor=fc, zorder=z))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=z + 1, linespacing=1.35)


def plain(x, y, w, h, label, ec, fc="white", fs=8.4, lw=1.3, z=3, rot=0):
    ax.add_patch(Rectangle((x, y), w, h, linewidth=lw, edgecolor=ec,
                 facecolor=fc, zorder=z))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=z + 1, rotation=rot,
            linespacing=1.3)


def arrow(x1, y1, x2, y2, c=INK, lw=1.7, ls="-", rad=0.0, ms=12, z=2):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=ms, linewidth=lw, color=c, linestyle=ls,
                 zorder=z, connectionstyle=f"arc3,rad={rad}"))


def lab(x, y, t, c=INK, fs=8.0, style="italic", ha="center", rot=0, fw="normal"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c, style=style,
            rotation=rot, fontweight=fw, zorder=6)


def mux(x, y, w, h, label, ec, sel=""):
    """Trapezoid mux."""
    ax.add_patch(plt.Polygon([[x, y], [x + w, y + h * 0.18],
                              [x + w, y + h * 0.82], [x, y + h]],
                 closed=True, linewidth=1.7, edgecolor=ec,
                 facecolor="white", zorder=3))
    ax.text(x + w * 0.45, y + h / 2, label, ha="center", va="center",
            fontsize=7.6, color=INK, zorder=4, rotation=90)
    if sel:
        lab(x + w * 0.5, y - 2.6, sel, MUT, 7.2)


# ======================================================================= title
ax.text(93, 117.5,
        "Day 40   RISC-V Sv32 MMU  —  fully-associative TLB + hardware page-table walker",
        ha="center", fontsize=15.0, fontweight="bold", color=INK)
ax.text(93, 113.6,
        "circuit / datapath schematic of the synthesized design  (hand-drawn figure, "
        "not a simulator capture)",
        ha="center", fontsize=9.4, color=MUT, style="italic")

# ================================================================ CPU + CSR in
box(3, 96, 34, 13,
    "CPU / LSU / fetch port\n"
    "req_valid, req_ready\n"
    "req_vaddr[31:0], req_access", CPU_C, "#f0f9ff", 9.0)

box(3, 78, 34, 14,
    "CSR / mode state\n"
    "satp.MODE, satp.PPN[21:0]\n"
    "priv[1:0], mstatus.SUM, .MXR\n"
    "sfence_valid", CSR_C, "#f0fdfa", 8.8)

# ---- VA split ---------------------------------------------------------------
box(45, 96, 46, 13, "", CPU_C, "#f0f9ff")
plain(46.6, 98.0, 14.2, 9.0, "vpn1\n[31:22]", CPU_C, "white", 8.4)
plain(61.4, 98.0, 14.2, 9.0, "vpn0\n[21:12]", CPU_C, "white", 8.4)
plain(76.2, 98.0, 13.2, 9.0, "offset\n[11:0]", MUT, "#f9fafb", 8.4)
lab(68, 94.2, "virtual-address split (wires only - no logic)", MUT, 7.8)
arrow(37, 102.5, 45, 102.5, CPU_C)

# ================================================================== TLB block
box(45, 52, 46, 37, "", TLB_C, "#faf5ff", lw=2.2)
lab(68, 86.6, f"TLB  —  fully associative, TLB_ENTRIES deep", TLB_C, 9.6, "normal",
    fw="bold")
lab(68, 83.4, "one CAM entry per cached page (4 KiB or 4 MiB)", MUT, 7.6)

cols = [("V", 4.0), ("vpn1", 7.6), ("vpn0", 7.6), ("S", 4.0),
        ("ppn[21:0]", 11.0), ("perm\nDAUXWR", 9.4)]
x0 = 46.6
hx = x0
for nm, w in cols:
    plain(hx, 77.6, w, 4.6, nm, MUT, "#f3f4f6", 7.2)
    hx += w

ROWS = [("1", "000", "005", "0", "001005", "111111"),
        ("1", "001", "  —", "1", "080000", "110011"),
        ("1", "004", "002", "0", "002002", "010100"),
        ("0", "  —", "  —", "-", "  —   ", "  —   ")]
ry = 72.6
for r in ROWS:
    hx = x0
    for (val, (nm, w)) in zip(r, cols):
        plain(hx, ry, w, 4.6, val, GRID, "white", 6.9)
        hx += w
    ry -= 4.8

lab(68, 54.6, "sfence_valid clears every V bit in one cycle (SFENCE.VMA)", FLT_C, 7.5)
arrow(20, 78, 20, 57, CSR_C, 1.4, ":")
arrow(20, 57, 45, 57, CSR_C, 1.4, ":")

# vpn1 / vpn0 feed the CAM
arrow(53.7, 98.0, 53.7, 89.0, CPU_C, 1.5)
arrow(68.5, 98.0, 68.5, 89.0, CPU_C, 1.5)

# ============================================================ comparators + hit
for i, yy in enumerate([73.0, 68.1, 63.2, 58.3]):
    plain(95.5, yy, 9.0, 4.6,
          "= &V", CMP_C, "#f0fdf4", 6.8)
    arrow(91, yy + 2.3, 95.5, yy + 2.3, TLB_C, 1.2, ms=9)
    arrow(104.5, yy + 2.3, 108.5, 66.0, CMP_C, 1.1, rad=0.10, ms=9)
lab(100, 77.0, "per-entry match", CMP_C, 7.4)
lab(100, 53.0, "vpn1 == && (S || vpn0 ==)", CMP_C, 6.9)

box(108.5, 61.0, 15, 10, "hit-OR\n+ index\nencode", CMP_C, "#f0fdf4", 8.2)
lab(116, 58.4, "tlb_hit", CMP_C, 7.8, "normal", fw="bold")

# entry mux: selected ppn + perm
box(108.5, 74.0, 15, 10, "entry mux\nppn, perm,\nS", TLB_C, "#faf5ff", 8.2)
arrow(116, 71.0, 116, 74.0, CMP_C, 1.4)
arrow(91, 79.0, 108.5, 79.0, TLB_C, 1.5)

# ---- megapage splice --------------------------------------------------------
box(128, 74.0, 20, 10,
    "megapage splice\nppn = S ? {ppn[21:10],\nvpn0} : ppn", TLB_C, "#faf5ff", 7.6)
arrow(123.5, 79.0, 128, 79.0, TLB_C)
arrow(68.5, 96.0, 138, 96.0, CPU_C, 1.2, ":", rad=0.0)
arrow(138, 96.0, 138, 84.0, CPU_C, 1.2, ":")
lab(120, 97.4, "vpn0 (megapage low bits)", CPU_C, 7.0)

# ---- permission check -------------------------------------------------------
box(128, 58.0, 20, 12,
    "permission check\nperm_ok(perm, acc,\npriv, SUM, MXR)", PRM_C, "#fdf2f8", 8.0)
arrow(123.5, 66.0, 128, 66.0, CMP_C)
arrow(37, 85.0, 138, 85.0, CSR_C, 1.2, ":", rad=-0.02)
arrow(138, 85.0, 138, 70.0, CSR_C, 1.2, ":")
lab(108, 87.4, "priv / SUM / MXR / access type", CSR_C, 7.0)

# ================================================================== response
mux(154, 74.0, 9, 14, "paddr mux", RSP_C, "sel: xlate_en, tlb_hit, walk done")
arrow(148, 79.0, 154, 81.0, TLB_C)
box(166, 94, 18, 15,
    "response\nresp_valid\nresp_paddr[33:0]\nresp_fault\nresp_cause[3:0]\nresp_super",
    RSP_C, "#eef2ff", 8.0)
arrow(163, 81.0, 175, 81.0, RSP_C)
arrow(175, 81.0, 175, 94.0, RSP_C)
arrow(148, 64.0, 175, 64.0, FLT_C, 1.5)
arrow(175, 64.0, 175, 79.0, FLT_C, 1.5)
lab(162, 62.4, "fault + cause (12 / 13 / 15)", FLT_C, 7.2)

# bare / M-mode bypass
arrow(83, 100.0, 152, 100.0, MUT, 1.4, "--")
arrow(152, 100.0, 156, 88.0, MUT, 1.4, "--")
lab(118, 101.6, "bare / M-mode bypass:  paddr = {2'b00, vaddr},  never faults",
    MUT, 7.6)

# ============================================================ page-table walker
box(3, 7, 118, 40, "", FSM_C, "#fffbeb", lw=2.2)
lab(62, 45.2, "hardware page-table walker  (engaged only on a TLB miss)",
    FSM_C, 10.0, "normal", fw="bold")

box(7, 24, 26, 15,
    "walk FSM\nIDLE -> REQ ->\nWAIT -> (descend)\n-> RESP", FSM_C, "white", 8.4)
box(7, 12, 26, 9,
    "walk_base[21:0]\nwalk_level (1 -> 0)", FSM_C, "white", 8.4)
arrow(20, 24, 20, 21, FSM_C, 1.4)
arrow(33, 16.5, 40, 16.5, FSM_C, 1.4)

# PTE address former
box(40, 22, 30, 12,
    "PTE address former\nptw_req_addr =\n{walk_base, vpn[level], 2'b00}",
    PTW_C, "#eff6ff", 8.0)
mux(40, 12, 8, 8, "vpn sel", PTW_C, "walk_level")
arrow(48, 16.0, 55, 22.0, PTW_C, 1.4)
arrow(53.7, 98.0, 36, 98.0, CPU_C, 1.1, ":")
arrow(36, 98.0, 36, 16.0, CPU_C, 1.1, ":")
arrow(36, 16.0, 40, 16.0, CPU_C, 1.1, ":")
lab(37.6, 20.5, "vpn1 / vpn0", CPU_C, 6.8, rot=90)

# memory port
box(77, 22, 26, 12,
    "walk memory port\nptw_req_valid/ready\nptw_resp_valid/data",
    PTW_C, "#eff6ff", 8.0)
arrow(70, 28, 77, 28, PTW_C)
lab(103.5, 35.6, "-> L2 / memory", PTW_C, 7.4)
arrow(103, 28, 112, 28, PTW_C)

# PTE decode
box(77, 8, 40, 12,
    "PTE decode\n"
    "!V or (W & !R)  ->  FAULT\n"
    "(R | X)  ->  LEAF     else  ->  POINTER\n"
    "level-1 leaf with ppn0 != 0  ->  misaligned FAULT\n"
    "POINTER at level 0  ->  FAULT",
    FSM_C, "white", 6.9)
arrow(90, 22, 90, 20, PTW_C, 1.4)

# install path back into the TLB
box(40, 34.8, 30, 7.6, "install leaf into TLB\n+ victim select:\ninvalid-first, else round-robin",
    TLB_C, "#faf5ff", 7.6)
arrow(77, 12.5, 74, 12.5, FSM_C, 1.4)
arrow(74, 12.5, 74, 38.6, FSM_C, 1.4)
arrow(74, 38.6, 70, 38.6, FSM_C, 1.4)
arrow(52, 42.4, 52, 52.0, TLB_C, 1.8)
lab(66, 48.8, "new TLB entry", TLB_C, 7.4)

# miss trigger + walk result out
arrow(116, 61.0, 116, 50.2, CMP_C, 1.4, "--")
arrow(116, 50.2, 20, 50.2, CMP_C, 1.4, "--")
arrow(20, 50.2, 20, 39.0, CMP_C, 1.4, "--")
lab(103, 48.7, "miss -> start walk", CMP_C, 7.4)
# walked result climbs at x = 121.5, i.e. just left of the inset panel
arrow(103, 26.0, 121.5, 26.0, RSP_C, 1.4, "--")
arrow(121.5, 26.0, 121.5, 78.0, RSP_C, 1.4, "--")
arrow(121.5, 78.0, 154, 78.0, RSP_C, 1.4, "--")
lab(112, 23.8, "walked paddr / fault\n(registered, 1-cycle RESP)", RSP_C, 7.0)

# ===================================================================== insets
IX, IY, IW = 125, 8, 59
ax.add_patch(FancyBboxPatch((IX, IY), IW, 44,
             boxstyle="round,pad=0.6,rounding_size=1.6",
             linewidth=1.5, edgecolor=GRID, facecolor="#fcfcfd", zorder=1))

lab(IX + IW / 2, IY + 41.0, "Sv32 PTE (32 bits)", INK, 9.0, "normal", fw="bold")
flds = [("ppn1[19:10]", 15.0), ("ppn0[9:0]", 12.5), ("RSW", 5.0),
        ("D", 3.0), ("A", 3.0), ("G", 3.0), ("U", 3.0),
        ("X", 3.0), ("W", 3.0), ("R", 3.0), ("V", 3.0)]
fx = IX + 1.5
for nm, w in flds:
    plain(fx, IY + 35.2, w, 4.4, nm, MUT, "white", 6.4)
    fx += w
lab(IX + 8, IY + 33.0, "31            20", MUT, 6.2)
lab(IX + 50, IY + 33.0, "7  6  5  4  3  2  1  0", MUT, 6.2)

lab(IX + IW / 2, IY + 29.4, "walk algorithm (2 levels, read-only)", INK, 9.0,
    "normal", fw="bold")
ax.text(IX + 2, IY + 27.6,
        "a = satp.ppn << 12 ;  i = 1\n"
        "loop:  pte = mem[a + vpn[i]*4]\n"
        "       if !pte.V or (pte.W and !pte.R)      -> page fault\n"
        "       if pte.R or pte.X                    -> leaf, goto check\n"
        "       if i == 0                            -> page fault\n"
        "       a = pte.ppn << 12 ;  i = i - 1 ;  goto loop\n"
        "check: if i == 1 and pte.ppn0 != 0          -> page fault (misaligned)\n"
        "       if !perm_ok(...)                     -> page fault\n"
        "       pa = {i ? {pte.ppn[21:10], vpn0} : pte.ppn, offset}",
        ha="left", va="top", fontsize=7.0, color=INK, family="monospace",
        linespacing=1.5, zorder=6)

lab(IX + IW / 2, IY + 10.4, "permission check", INK, 9.0, "normal", fw="bold")
ax.text(IX + 2, IY + 8.8,
        "U-mode:  needs pte.U            S-mode: pte.U needs SUM (data only)\n"
        "fetch -> pte.X    store -> pte.W    load -> pte.R or (MXR and pte.X)\n"
        "always needs pte.A ;  a store also needs pte.D  (else fault: software\n"
        "sets A/D - this MMU never writes a PTE)",
        ha="left", va="top", fontsize=7.0, color=INK, family="monospace",
        linespacing=1.5, zorder=6)

# ---- latency note -----------------------------------------------------------
ax.text(3, 1.2,
        "Latency:  bare / M-mode and TLB hit answer in ZERO cycles (combinational, same cycle as req_valid).  "
        "A TLB miss costs one page-table walk:\n"
        "two dependent PTE reads for a 4 KiB page, one for a 4 MiB megapage, plus whatever latency the memory "
        "port adds - then the leaf is cached.",
        ha="left", va="bottom", fontsize=8.4, color=MUT, linespacing=1.6)

plt.tight_layout(rect=(0.005, 0.005, 0.995, 0.995))
fig.savefig("docs/mmu_sv32_block.png", dpi=140, facecolor="white")
print("wrote docs/mmu_sv32_block.png")
