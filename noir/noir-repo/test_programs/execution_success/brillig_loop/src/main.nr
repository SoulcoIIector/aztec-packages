// Tests a very simple program.
//
// The features being tested is basic looping on brillig
fn main(sum: u32) {
    unsafe {
        assert(loop(4) == sum);
        assert(loop_incl(3) == sum);
        assert(plain_loop() == sum);
    }
}

unconstrained fn loop(x: u32) -> u32 {
    let mut sum = 0;
    for i in 0..x {
        sum = sum + i;
    }
    sum
}

unconstrained fn loop_incl(x: u32) -> u32 {
    let mut sum = 0;
    for i in 0..=x {
        sum = sum + i;
    }
    sum
}

unconstrained fn plain_loop() -> u32 {
    let mut sum = 0;
    for i in 0..4 {
        sum = sum + i;
    }
    sum
}
