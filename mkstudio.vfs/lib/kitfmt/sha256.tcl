# sha256.tcl -- SHA-256 (FIPS 180-4) in pure Tcl, for kitfmt's fallback hash path.
#
#   ::kitfmt::sha256::hex data      -> 64 lowercase hex digits of SHA-256(data)
#
# `data` is treated as bytes (a byte array; characters above \xff are an error).
# Tcl 8.5 to 9 compatible: 32-bit words are kept in wide integers and masked.
# This is the slow path (about 0.5-1 MB/s); kitfmt prefers kithelper, sha256sum or an
# accelerated tcllib whenever one is there (see kitfmt.tcl, "Hashing").

namespace eval ::kitfmt::sha256 {
    variable K {
        0x428a2f98 0x71374491 0xb5c0fbcf 0xe9b5dba5 0x3956c25b 0x59f111f1 0x923f82a4 0xab1c5ed5
        0xd807aa98 0x12835b01 0x243185be 0x550c7dc3 0x72be5d74 0x80deb1fe 0x9bdc06a7 0xc19bf174
        0xe49b69c1 0xefbe4786 0x0fc19dc6 0x240ca1cc 0x2de92c6f 0x4a7484aa 0x5cb0a9dc 0x76f988da
        0x983e5152 0xa831c66d 0xb00327c8 0xbf597fc7 0xc6e00bf3 0xd5a79147 0x06ca6351 0x14292967
        0x27b70a85 0x2e1b2138 0x4d2c6dfc 0x53380d13 0x650a7354 0x766a0abb 0x81c2c92e 0x92722c85
        0xa2bfe8a1 0xa81a664b 0xc24b8b70 0xc76c51a3 0xd192e819 0xd6990624 0xf40e3585 0x106aa070
        0x19a4c116 0x1e376c08 0x2748774c 0x34b0bcb5 0x391c0cb3 0x4ed8aa4a 0x5b9cca4f 0x682e6ff3
        0x748f82ee 0x78a5636f 0x84c87814 0x8cc70208 0x90befffa 0xa4506ceb 0xbef9a3f7 0xc67178f2
    }
}

proc ::kitfmt::sha256::hex {data} {
    variable K
    set len [string length $data]
    # padding: 0x80, zeros, 64-bit big-endian bit length
    set bits [expr {wide($len) * 8}]
    set padlen [expr {(55 - $len) % 64}]
    if {$padlen < 0} { incr padlen 64 }
    append data \x80 [string repeat \x00 $padlen] \
        [binary format II [expr {($bits >> 32) & 0xffffffff}] [expr {$bits & 0xffffffff}]]
    set h0 0x6a09e667 ; set h1 0xbb67ae85 ; set h2 0x3c6ef372 ; set h3 0xa54ff53a
    set h4 0x510e527f ; set h5 0x9b05688c ; set h6 0x1f83d9ab ; set h7 0x5be0cd19
    set n [string length $data]
    for {set off 0} {$off < $n} {incr off 64} {
        binary scan $data @${off}I16 w
        set W {}
        foreach x $w { lappend W [expr {$x & 0xffffffff}] }
        for {set t 16} {$t < 64} {incr t} {
            set x [lindex $W [expr {$t - 15}]]
            set y [lindex $W [expr {$t - 2}]]
            set s0 [expr {((($x >> 7) | ($x << 25)) ^ (($x >> 18) | ($x << 14)) ^ ($x >> 3)) & 0xffffffff}]
            set s1 [expr {((($y >> 17) | ($y << 15)) ^ (($y >> 19) | ($y << 13)) ^ ($y >> 10)) & 0xffffffff}]
            lappend W [expr {([lindex $W [expr {$t - 16}]] + $s0 + [lindex $W [expr {$t - 7}]] + $s1) & 0xffffffff}]
        }
        set a $h0 ; set b $h1 ; set c $h2 ; set d $h3 ; set e $h4 ; set f $h5 ; set g $h6 ; set h $h7
        foreach k $K wt $W {
            set t1 [expr {($h + (((($e >> 6) | ($e << 26)) ^ (($e >> 11) | ($e << 21)) ^ (($e >> 25) | ($e << 7))) & 0xffffffff)
                          + (($e & $f) ^ (~$e & $g)) + $k + $wt) & 0xffffffff}]
            set t2 [expr {(((($a >> 2) | ($a << 30)) ^ (($a >> 13) | ($a << 19)) ^ (($a >> 22) | ($a << 10))) & 0xffffffff)
                          + (($a & $b) ^ ($a & $c) ^ ($b & $c))}]
            set h $g ; set g $f ; set f $e
            set e [expr {($d + $t1) & 0xffffffff}]
            set d $c ; set c $b ; set b $a
            set a [expr {($t1 + $t2) & 0xffffffff}]
        }
        set h0 [expr {($h0 + $a) & 0xffffffff}] ; set h1 [expr {($h1 + $b) & 0xffffffff}]
        set h2 [expr {($h2 + $c) & 0xffffffff}] ; set h3 [expr {($h3 + $d) & 0xffffffff}]
        set h4 [expr {($h4 + $e) & 0xffffffff}] ; set h5 [expr {($h5 + $f) & 0xffffffff}]
        set h6 [expr {($h6 + $g) & 0xffffffff}] ; set h7 [expr {($h7 + $h) & 0xffffffff}]
    }
    return [format %08x%08x%08x%08x%08x%08x%08x%08x $h0 $h1 $h2 $h3 $h4 $h5 $h6 $h7]
}
