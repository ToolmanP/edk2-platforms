/** @file
 *
 *  Copyright (c) 2020, Andrei Warkentin <andrey.warkentin@gmail.com>
 *  Copyright (c) 2019-2020, Pete Batard <pete@akeo.ie>
 *  Copyright (c) 2016, Linaro Limited. All rights reserved.
 *  Copyright (c) 2011-2020, ARM Limited. All rights reserved.
 *
 *  SPDX-License-Identifier: BSD-2-Clause-Patent
 *
 **/

#include <AsmMacroLib.h>
#include <Library/ArmLib.h>
#include <IndustryStandard/Bcm2836.h>
#include <IndustryStandard/RpiMbox.h>

    .macro  drain
    mov     x5, #RPI_MBOX_MAX_TRIES
0:  ldr     w6, [x4, #BCM2836_MBOX_STATUS_OFFSET]
    tbnz    w6, #BCM2836_MBOX_STATUS_EMPTY, 1f
    dmb     ld
    ldr     wzr, [x4, #BCM2836_MBOX_READ_OFFSET]
    subs    x5, x5, #1
    b.ne    0b
1:
    .endm

    .macro  poll, status
    mov     x5, #RPI_MBOX_MAX_TRIES
0:  ldr     w6, [x4, #BCM2836_MBOX_STATUS_OFFSET]
    tbz     w6, #\status, 1f
    dmb     ld
    subs    x5, x5, #1
    b.ne    0b
1:
    .endm

    .macro  run, command_buffer
    adr     x0, \command_buffer
    orr     x0, x0, #RPI_MBOX_VC_CHANNEL
    add     x0, x0, x1

    poll    BCM2836_MBOX_STATUS_FULL
    str     w0, [x4, #BCM2836_MBOX_WRITE_OFFSET]
    dmb     sy
    poll    BCM2836_MBOX_STATUS_EMPTY
    dmb     sy
    ldr     wzr, [x4, #BCM2836_MBOX_READ_OFFSET]
    dmb     ld
    .endm

#define CURRENTEL_EL1           (0b01 << 2)
#define CURRENTEL_EL2           (0b10 << 2)

#define CPACR_EL1_FPEN          (0b11 << 20)
#define ID_AA64PFR0_EL1_GIC     (0b1111 << 24)

#define CNTHCTL_EL2_EL1PCEN     (1 << 1)
#define CNTHCTL_EL2_EL1PCTEN    (1 << 0)
#define CPTR_EL2_RES1           0x33ff
#define HCR_EL2_RW              (1 << 31)
#define ICC_SRE_EL2_SRE         (1 << 0)
#define ICC_SRE_EL2_ENABLE      (1 << 3)

#define SCR_EL3_HCE             (1 << 8)
#define SCR_EL3_NS              (1 << 0)
#define SCR_EL3_RW              (1 << 10)

#define SPSR_ELX_DAIF           (0b1111 << 6)
#define SPSR_ELX_EL1H           (0b0101)

#define ICH_HCR_EL2             S3_4_C12_C11_0
#define ICC_SRE_EL2             S3_4_C12_C9_5

ASM_FUNC (ARM_ELX_TO_EL1)
	mrs x9, CurrentEL

	// Check the current exception level.
	cmp x9, CURRENTEL_EL1
	beq .Ltarget
	cmp x9, CURRENTEL_EL2
	beq .Lin_el2
	// Otherwise, we are in EL3.

	// Set EL2 to 64bit and enable the HVC instruction.
	mrs x9, scr_el3
	mov x10, SCR_EL3_NS | SCR_EL3_HCE | SCR_EL3_RW
	orr x9, x9, x10
	msr scr_el3, x9

	// Set the return address and exception level.
	adr x9, .Ltarget
	msr elr_el3, x9
	mov x9, SPSR_ELX_DAIF | SPSR_ELX_EL1H
	msr spsr_el3, x9

.Lin_el2:
	// Disable EL1 timer traps and the timer offset.
	mrs x9, cnthctl_el2
	orr x9, x9, CNTHCTL_EL2_EL1PCEN | CNTHCTL_EL2_EL1PCTEN
	msr cnthctl_el2, x9
	msr cntvoff_el2, xzr

	// Disable stage 2 translations.
	msr vttbr_el2, xzr

	// Disable EL2 coprocessor traps.
	mov x9, CPTR_EL2_RES1
	msr cptr_el2, x9

	// Disable EL1 FPU traps.
	mov x9, CPACR_EL1_FPEN
	msr cpacr_el1, x9

	// Check whether the GIC system registers are supported.
	mrs x9, id_aa64pfr0_el1
	and x9, x9, ID_AA64PFR0_EL1_GIC
	cbz x9, .Lno_gic_sr

	// Enable the GIC system registers in EL2, and allow their use in EL1.
	mrs x9, ICC_SRE_EL2
	mov x10, ICC_SRE_EL2_ENABLE | ICC_SRE_EL2_SRE
	orr x9, x9, x10
	msr ICC_SRE_EL2, x9

	// Disable the GIC virtual CPU interface.
	msr ICH_HCR_EL2, xzr

.Lno_gic_sr:
	// Set EL1 to 64bit.
	mov x9, HCR_EL2_RW
	msr hcr_el2, x9

	// Set the return address and exception level.
	adr x9, .Ltarget
	msr elr_el2, x9
	mov x9, SPSR_ELX_DAIF | SPSR_ELX_EL1H
	msr spsr_el2, x9

	isb
	eret

.Ltarget:
	ret

ASM_FUNC (ArmPlatformPeiBootAction)

    mov     x1, lr
    bl      ASM_PFX(ARM_ELX_TO_EL1)
    mov     lr, x1
    mov     x1, #FixedPcdGet64 (PcdDmaDeviceOffset)
    orr     x0, x0, #RPI_MBOX_VC_CHANNEL
    // x1 holds the value of PcdDmaDeviceOffset throughout this function

    MOV32   (x4, BCM2836_MBOX_BASE_ADDRESS)

    drain

    run     .Lmeminfo_buffer

    ldr     w0, .Lmembase
    adr     x2, mSystemMemoryBase
    str     x0, [x2]

    ldr     w0, .Lmemsize
    sub     x0, x0, #1
    adr     x2, mSystemMemoryEnd
    str     x0, [x2]

    run     .Lvcinfo_buffer

    ldr     w0, .Lvcbase
    adr     x2, mVideoCoreBase
    str     x0, [x2]

    ldr     w0, .Lvcsize
    adr     x2, mVideoCoreSize
    str     x0, [x2]

    run     .Lrevinfo_buffer

    ldr     w0, .Lrevision
    adr     x2, mBoardRevision
    str     w0, [x2]

    run     .Lclkinfo_buffer

    ldr     w0, .Lfrequency
    adr     x2, _gPcd_BinaryPatch_PcdSerialClockRate
    str     w0, [x2]

    ret

    .align  4
.Lmeminfo_buffer:
    .long   .Lmeminfo_size
    .long   0x0
    .long   RPI_MBOX_GET_ARM_MEMSIZE
    .long   8                           // buf size
    .long   0                           // input len
.Lmembase:
    .long   0                           // mem base
.Lmemsize:
    .long   0                           // mem size
    .long   0                           // end tag
    .set    .Lmeminfo_size, . - .Lmeminfo_buffer

    .align  4
.Lvcinfo_buffer:
    .long   .Lvcinfo_size
    .long   0x0
    .long   RPI_MBOX_GET_VC_MEMSIZE
    .long   8                           // buf size
    .long   0                           // input len
.Lvcbase:
    .long   0                           // videocore base
.Lvcsize:
    .long   0                           // videocore size
    .long   0                           // end tag
    .set    .Lvcinfo_size, . - .Lvcinfo_buffer

    .align  4
.Lrevinfo_buffer:
    .long   .Lrevinfo_size
    .long   0x0
    .long   RPI_MBOX_GET_BOARD_REVISION
    .long   4                           // buf size
    .long   0                           // input len
.Lrevision:
    .long   0                           // revision
    .long   0                           // end tag
    .set    .Lrevinfo_size, . - .Lrevinfo_buffer

    .align  4
.Lclkinfo_buffer:
    .long   .Lclkinfo_size
    .long   0x0
    .long   RPI_MBOX_GET_CLOCK_RATE
    .long   8                           // buf size
    .long   4                           // input len
    .long   4                           // clock id: 0x04 = Core/VPU
.Lfrequency:
    .long   0                           // frequency
    .long   0                           // end tag
    .set    .Lclkinfo_size, . - .Lclkinfo_buffer

ASM_FUNCTION_REMOVE_IF_UNREFERENCED
