use crate::runtime::is_unconstrained;

// Implementation of SHA-256 mapping a byte array of variable length to
// 32 bytes.

// A message block is up to 64 bytes taken from the input.
global BLOCK_SIZE = 64;

// The first index in the block where the 8 byte message size will be written.
global MSG_SIZE_PTR = 56;

// Size of the message block when packed as 4-byte integer array.
global INT_BLOCK_SIZE = 16;

// Index of a byte in a 64 byte block; ie. 0..=63
type BLOCK_BYTE_PTR = u32;

// The foreign function to compress blocks works on 16 pieces of 4-byte integers, instead of 64 bytes.
type INT_BLOCK = [u32; INT_BLOCK_SIZE];

// A message block is a slice of the original message of a fixed size,
// potentially padded with zeroes.
type MSG_BLOCK = [u8; BLOCK_SIZE];

// The hash is 32 bytes.
type HASH = [u8; 32];

// The state accumulates the blocks.
// Its overall size is the same as the `HASH`.
type STATE = [u32; 8];

// Deprecated in favour of `sha256_var`
// docs:start:sha256
pub fn sha256<let N: u32>(input: [u8; N]) -> HASH
// docs:end:sha256
{
    digest(input)
}

#[foreign(sha256_compression)]
pub fn sha256_compression(_input: INT_BLOCK, _state: STATE) -> STATE {}

// SHA-256 hash function
#[no_predicates]
pub fn digest<let N: u32>(msg: [u8; N]) -> HASH {
    sha256_var(msg, N as u64)
}

// Variable size SHA-256 hash
pub fn sha256_var<let N: u32>(msg: [u8; N], message_size: u64) -> HASH {
    let message_size = message_size as u32;
    let num_blocks = N / BLOCK_SIZE;
    let mut msg_block: MSG_BLOCK = [0; BLOCK_SIZE];
    let mut h: STATE = [
        1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635,
        1541459225,
    ]; // Intermediate hash, starting with the canonical initial value
    let mut msg_byte_ptr = 0; // Pointer into msg_block
    for i in 0..num_blocks {
        let msg_start = BLOCK_SIZE * i;
        let (new_msg_block, new_msg_byte_ptr) =
            unsafe { build_msg_block(msg, message_size, msg_start) };
        if msg_start < message_size {
            msg_block = new_msg_block;
        }

        if !is_unconstrained() {
            // Verify the block we are compressing was appropriately constructed
            let new_msg_byte_ptr = verify_msg_block(msg, message_size, msg_block, msg_start);
            if msg_start < message_size {
                msg_byte_ptr = new_msg_byte_ptr;
            }
        } else if msg_start < message_size {
            msg_byte_ptr = new_msg_byte_ptr;
        }

        // If the block is filled, compress it.
        // An un-filled block is handled after this loop.
        if (msg_start < message_size) & (msg_byte_ptr == BLOCK_SIZE) {
            h = sha256_compression(msg_u8_to_u32(msg_block), h);
        }
    }

    let modulo = N % BLOCK_SIZE;
    // Handle setup of the final msg block.
    // This case is only hit if the msg is less than the block size,
    // or our message cannot be evenly split into blocks.
    if modulo != 0 {
        let msg_start = BLOCK_SIZE * num_blocks;
        let (new_msg_block, new_msg_byte_ptr) =
            unsafe { build_msg_block(msg, message_size, msg_start) };

        if msg_start < message_size {
            msg_block = new_msg_block;
        }

        if !is_unconstrained() {
            let new_msg_byte_ptr = verify_msg_block(msg, message_size, msg_block, msg_start);
            if msg_start < message_size {
                msg_byte_ptr = new_msg_byte_ptr;
                verify_msg_block_padding(msg_block, msg_byte_ptr);
            }
        } else if msg_start < message_size {
            msg_byte_ptr = new_msg_byte_ptr;
        }
    }

    // If we had modulo == 0 then it means the last block was full,
    // and we can reset the pointer to zero to overwrite it.
    if msg_byte_ptr == BLOCK_SIZE {
        msg_byte_ptr = 0;
    }

    // Pad the rest such that we have a [u32; 2] block at the end representing the length
    // of the message, and a block of 1 0 ... 0 following the message (i.e. [1 << 7, 0, ..., 0]).
    // Here we rely on the fact that everything beyond the available input is set to 0.
    msg_block[msg_byte_ptr] = 1 << 7;
    let last_block = msg_block;
    msg_byte_ptr = msg_byte_ptr + 1;

    // If we don't have room to write the size, compress the block and reset it.
    if msg_byte_ptr > MSG_SIZE_PTR {
        h = sha256_compression(msg_u8_to_u32(msg_block), h);
        // `attach_len_to_msg_block` will zero out everything after the `msg_byte_ptr`.
        msg_byte_ptr = 0;
    }

    msg_block = unsafe { attach_len_to_msg_block(msg_block, msg_byte_ptr, message_size) };

    if !crate::runtime::is_unconstrained() {
        verify_msg_len(msg_block, last_block, msg_byte_ptr, message_size);
    }

    hash_final_block(msg_block, h)
}

// Convert 64-byte array to array of 16 u32s
fn msg_u8_to_u32(msg: MSG_BLOCK) -> INT_BLOCK {
    let mut msg32: INT_BLOCK = [0; INT_BLOCK_SIZE];

    for i in 0..INT_BLOCK_SIZE {
        let mut msg_field: Field = 0;
        for j in 0..4 {
            msg_field = msg_field * 256 + msg[64 - 4 * (i + 1) + j] as Field;
        }
        msg32[15 - i] = msg_field as u32;
    }

    msg32
}

// Take `BLOCK_SIZE` number of bytes from `msg` starting at `msg_start`.
// Returns the block and the length that has been copied rather than padded with zeroes.
unconstrained fn build_msg_block<let N: u32>(
    msg: [u8; N],
    message_size: u32,
    msg_start: u32,
) -> (MSG_BLOCK, BLOCK_BYTE_PTR) {
    let mut msg_block: MSG_BLOCK = [0; BLOCK_SIZE];
    // We insert `BLOCK_SIZE` bytes (or up to the end of the message)
    let block_input = if msg_start + BLOCK_SIZE > message_size {
        if message_size < msg_start {
            // This function is sometimes called with `msg_start` past the end of the message.
            // In this case we return an empty block and zero pointer to signal that the result should be ignored.
            0
        } else {
            message_size - msg_start
        }
    } else {
        BLOCK_SIZE
    };
    for k in 0..block_input {
        msg_block[k] = msg[msg_start + k];
    }
    (msg_block, block_input)
}

// Verify the block we are compressing was appropriately constructed by `build_msg_block`
// and matches the input data. Returns the index of the first unset item.
fn verify_msg_block<let N: u32>(
    msg: [u8; N],
    message_size: u32,
    msg_block: MSG_BLOCK,
    msg_start: u32,
) -> BLOCK_BYTE_PTR {
    let mut msg_byte_ptr: u32 = 0; // Message byte pointer
    let mut msg_end = msg_start + BLOCK_SIZE;
    if msg_end > N {
        msg_end = N;
    }

    for k in msg_start..msg_end {
        if k < message_size {
            assert_eq(msg_block[msg_byte_ptr], msg[k]);
            msg_byte_ptr = msg_byte_ptr + 1;
        }
    }

    msg_byte_ptr
}

// Verify the block we are compressing was appropriately padded with zeroes by `build_msg_block`.
// This is only relevant for the last, potentially partially filled block.
fn verify_msg_block_padding(msg_block: MSG_BLOCK, msg_byte_ptr: BLOCK_BYTE_PTR) {
    // This variable is used to get around the compiler under-constrained check giving a warning.
    // We want to check against a constant zero, but if it does not come from the circuit inputs
    // or return values the compiler check will issue a warning.
    let zero = msg_block[0] - msg_block[0];

    for i in 0..BLOCK_SIZE {
        if i >= msg_byte_ptr {
            assert_eq(msg_block[i], zero);
        }
    }
}

// Zero out all bytes between the end of the message and where the length is appended,
// then write the length into the last 8 bytes of the block.
unconstrained fn attach_len_to_msg_block(
    mut msg_block: MSG_BLOCK,
    msg_byte_ptr: BLOCK_BYTE_PTR,
    message_size: u32,
) -> MSG_BLOCK {
    // We assume that `msg_byte_ptr` is less than 57 because if not then it is reset to zero before calling this function.
    // In any case, fill blocks up with zeros until the last 64 (i.e. until msg_byte_ptr = 56).
    for i in msg_byte_ptr..MSG_SIZE_PTR {
        msg_block[i] = 0;
    }

    let len = 8 * message_size;
    let len_bytes: [u8; 8] = (len as Field).to_be_bytes();
    for i in 0..8 {
        msg_block[MSG_SIZE_PTR + i] = len_bytes[i];
    }
    msg_block
}

// Verify that the message length was correctly written by `attach_len_to_msg_block`.
fn verify_msg_len(
    msg_block: MSG_BLOCK,
    last_block: MSG_BLOCK,
    msg_byte_ptr: BLOCK_BYTE_PTR,
    message_size: u32,
) {
    for i in 0..MSG_SIZE_PTR {
        let predicate = (i < msg_byte_ptr) as u8;
        let expected_byte = predicate * last_block[i];
        assert_eq(msg_block[i], expected_byte);
    }

    // We verify the message length was inserted correctly by reversing the byte decomposition.
    let len = 8 * message_size;
    let mut reconstructed_len: Field = 0;
    for i in MSG_SIZE_PTR..BLOCK_SIZE {
        reconstructed_len = 256 * reconstructed_len + msg_block[i] as Field;
    }
    assert_eq(reconstructed_len, len as Field);
}

// Perform the final compression, then transform the `STATE` into `HASH`.
fn hash_final_block(msg_block: MSG_BLOCK, mut state: STATE) -> HASH {
    let mut out_h: HASH = [0; 32]; // Digest as sequence of bytes
    // Hash final padded block
    state = sha256_compression(msg_u8_to_u32(msg_block), state);

    // Return final hash as byte array
    for j in 0..8 {
        let h_bytes: [u8; 4] = (state[7 - j] as Field).to_le_bytes();
        for k in 0..4 {
            out_h[31 - 4 * j - k] = h_bytes[k];
        }
    }

    out_h
}

mod tests {
    use super::sha256_var;

    #[test]
    fn smoke_test() {
        let input = [0xbd];
        let result = [
            0x68, 0x32, 0x57, 0x20, 0xaa, 0xbd, 0x7c, 0x82, 0xf3, 0x0f, 0x55, 0x4b, 0x31, 0x3d,
            0x05, 0x70, 0xc9, 0x5a, 0xcc, 0xbb, 0x7d, 0xc4, 0xb5, 0xaa, 0xe1, 0x12, 0x04, 0xc0,
            0x8f, 0xfe, 0x73, 0x2b,
        ];
        assert_eq(sha256_var(input, input.len() as u64), result);
    }

    #[test]
    fn msg_just_over_block() {
        let input = [
            102, 114, 111, 109, 58, 114, 117, 110, 110, 105, 101, 114, 46, 108, 101, 97, 103, 117,
            101, 115, 46, 48, 106, 64, 105, 99, 108, 111, 117, 100, 46, 99, 111, 109, 13, 10, 99,
            111, 110, 116, 101, 110, 116, 45, 116, 121, 112, 101, 58, 116, 101, 120, 116, 47, 112,
            108, 97, 105, 110, 59, 32, 99, 104, 97, 114, 115, 101, 116,
        ];
        let result = [
            91, 122, 146, 93, 52, 109, 133, 148, 171, 61, 156, 70, 189, 238, 153, 7, 222, 184, 94,
            24, 65, 114, 192, 244, 207, 199, 87, 232, 192, 224, 171, 207,
        ];
        assert_eq(sha256_var(input, input.len() as u64), result);
    }

    #[test]
    fn msg_multiple_over_block() {
        let input = [
            102, 114, 111, 109, 58, 114, 117, 110, 110, 105, 101, 114, 46, 108, 101, 97, 103, 117,
            101, 115, 46, 48, 106, 64, 105, 99, 108, 111, 117, 100, 46, 99, 111, 109, 13, 10, 99,
            111, 110, 116, 101, 110, 116, 45, 116, 121, 112, 101, 58, 116, 101, 120, 116, 47, 112,
            108, 97, 105, 110, 59, 32, 99, 104, 97, 114, 115, 101, 116, 61, 117, 115, 45, 97, 115,
            99, 105, 105, 13, 10, 109, 105, 109, 101, 45, 118, 101, 114, 115, 105, 111, 110, 58, 49,
            46, 48, 32, 40, 77, 97, 99, 32, 79, 83, 32, 88, 32, 77, 97, 105, 108, 32, 49, 54, 46,
            48, 32, 92, 40, 51, 55, 51, 49, 46, 53, 48, 48, 46, 50, 51, 49, 92, 41, 41, 13, 10, 115,
            117, 98, 106, 101, 99, 116, 58, 72, 101, 108, 108, 111, 13, 10, 109, 101, 115, 115, 97,
            103, 101, 45, 105, 100, 58, 60, 56, 70, 56, 49, 57, 68, 51, 50, 45, 66, 54, 65, 67, 45,
            52, 56, 57, 68, 45, 57, 55, 55, 70, 45, 52, 51, 56, 66, 66, 67, 52, 67, 65, 66, 50, 55,
            64, 109, 101, 46, 99, 111, 109, 62, 13, 10, 100, 97, 116, 101, 58, 83, 97, 116, 44, 32,
            50, 54, 32, 65, 117, 103, 32, 50, 48, 50, 51, 32, 49, 50, 58, 50, 53, 58, 50, 50, 32,
            43, 48, 52, 48, 48, 13, 10, 116, 111, 58, 122, 107, 101, 119, 116, 101, 115, 116, 64,
            103, 109, 97, 105, 108, 46, 99, 111, 109, 13, 10, 100, 107, 105, 109, 45, 115, 105, 103,
            110, 97, 116, 117, 114, 101, 58, 118, 61, 49, 59, 32, 97, 61, 114, 115, 97, 45, 115,
            104, 97, 50, 53, 54, 59, 32, 99, 61, 114, 101, 108, 97, 120, 101, 100, 47, 114, 101,
            108, 97, 120, 101, 100, 59, 32, 100, 61, 105, 99, 108, 111, 117, 100, 46, 99, 111, 109,
            59, 32, 115, 61, 49, 97, 49, 104, 97, 105, 59, 32, 116, 61, 49, 54, 57, 51, 48, 51, 56,
            51, 51, 55, 59, 32, 98, 104, 61, 55, 120, 81, 77, 68, 117, 111, 86, 86, 85, 52, 109, 48,
            87, 48, 87, 82, 86, 83, 114, 86, 88, 77, 101, 71, 83, 73, 65, 83, 115, 110, 117, 99, 75,
            57, 100, 74, 115, 114, 99, 43, 118, 85, 61, 59, 32, 104, 61, 102, 114, 111, 109, 58, 67,
            111, 110, 116, 101, 110, 116, 45, 84, 121, 112, 101, 58, 77, 105, 109, 101, 45, 86, 101,
            114, 115, 105, 111, 110, 58, 83, 117, 98, 106, 101, 99,
        ];
        let result = [
            116, 90, 151, 31, 78, 22, 138, 180, 211, 189, 69, 76, 227, 200, 155, 29, 59, 123, 154,
            60, 47, 153, 203, 129, 157, 251, 48, 2, 79, 11, 65, 47,
        ];
        assert_eq(sha256_var(input, input.len() as u64), result);
    }

    #[test]
    fn msg_just_under_block() {
        let input = [
            102, 114, 111, 109, 58, 114, 117, 110, 110, 105, 101, 114, 46, 108, 101, 97, 103, 117,
            101, 115, 46, 48, 106, 64, 105, 99, 108, 111, 117, 100, 46, 99, 111, 109, 13, 10, 99,
            111, 110, 116, 101, 110, 116, 45, 116, 121, 112, 101, 58, 116, 101, 120, 116, 47, 112,
            108, 97, 105, 110, 59,
        ];
        let result = [
            143, 140, 76, 173, 222, 123, 102, 68, 70, 149, 207, 43, 39, 61, 34, 79, 216, 252, 213,
            165, 74, 16, 110, 74, 29, 64, 138, 167, 30, 1, 9, 119,
        ];
        assert_eq(sha256_var(input, input.len() as u64), result);
    }

    #[test]
    fn msg_big_not_block_multiple() {
        let input = [
            102, 114, 111, 109, 58, 114, 117, 110, 110, 105, 101, 114, 46, 108, 101, 97, 103, 117,
            101, 115, 46, 48, 106, 64, 105, 99, 108, 111, 117, 100, 46, 99, 111, 109, 13, 10, 99,
            111, 110, 116, 101, 110, 116, 45, 116, 121, 112, 101, 58, 116, 101, 120, 116, 47, 112,
            108, 97, 105, 110, 59, 32, 99, 104, 97, 114, 115, 101, 116, 61, 117, 115, 45, 97, 115,
            99, 105, 105, 13, 10, 109, 105, 109, 101, 45, 118, 101, 114, 115, 105, 111, 110, 58, 49,
            46, 48, 32, 40, 77, 97, 99, 32, 79, 83, 32, 88, 32, 77, 97, 105, 108, 32, 49, 54, 46,
            48, 32, 92, 40, 51, 55, 51, 49, 46, 53, 48, 48, 46, 50, 51, 49, 92, 41, 41, 13, 10, 115,
            117, 98, 106, 101, 99, 116, 58, 72, 101, 108, 108, 111, 13, 10, 109, 101, 115, 115, 97,
            103, 101, 45, 105, 100, 58, 60, 56, 70, 56, 49, 57, 68, 51, 50, 45, 66, 54, 65, 67, 45,
            52, 56, 57, 68, 45, 57, 55, 55, 70, 45, 52, 51, 56, 66, 66, 67, 52, 67, 65, 66, 50, 55,
            64, 109, 101, 46, 99, 111, 109, 62, 13, 10, 100, 97, 116, 101, 58, 83, 97, 116, 44, 32,
            50, 54, 32, 65, 117, 103, 32, 50, 48, 50, 51, 32, 49, 50, 58, 50, 53, 58, 50, 50, 32,
            43, 48, 52, 48, 48, 13, 10, 116, 111, 58, 122, 107, 101, 119, 116, 101, 115, 116, 64,
            103, 109, 97, 105, 108, 46, 99, 111, 109, 13, 10, 100, 107, 105, 109, 45, 115, 105, 103,
            110, 97, 116, 117, 114, 101, 58, 118, 61, 49, 59, 32, 97, 61, 114, 115, 97, 45, 115,
            104, 97, 50, 53, 54, 59, 32, 99, 61, 114, 101, 108, 97, 120, 101, 100, 47, 114, 101,
            108, 97, 120, 101, 100, 59, 32, 100, 61, 105, 99, 108, 111, 117, 100, 46, 99, 111, 109,
            59, 32, 115, 61, 49, 97, 49, 104, 97, 105, 59, 32, 116, 61, 49, 54, 57, 51, 48, 51, 56,
            51, 51, 55, 59, 32, 98, 104, 61, 55, 120, 81, 77, 68, 117, 111, 86, 86, 85, 52, 109, 48,
            87, 48, 87, 82, 86, 83, 114, 86, 88, 77, 101, 71, 83, 73, 65, 83, 115, 110, 117, 99, 75,
            57, 100, 74, 115, 114, 99, 43, 118, 85, 61, 59, 32, 104, 61, 102, 114, 111, 109, 58, 67,
            111, 110, 116, 101, 110, 116, 45, 84, 121, 112, 101, 58, 77, 105, 109, 101, 45, 86, 101,
            114, 115, 105, 111, 110, 58, 83, 117, 98, 106, 101, 99, 116, 58, 77, 101, 115, 115, 97,
            103, 101, 45, 73, 100, 58, 68, 97, 116, 101, 58, 116, 111, 59, 32, 98, 61,
        ];
        let result = [
            112, 144, 73, 182, 208, 98, 9, 238, 54, 229, 61, 145, 222, 17, 72, 62, 148, 222, 186,
            55, 192, 82, 220, 35, 66, 47, 193, 200, 22, 38, 26, 186,
        ];
        assert_eq(sha256_var(input, input.len() as u64), result);
    }

    #[test]
    fn msg_big_with_padding() {
        let input = [
            48, 130, 1, 37, 2, 1, 0, 48, 11, 6, 9, 96, 134, 72, 1, 101, 3, 4, 2, 1, 48, 130, 1, 17,
            48, 37, 2, 1, 1, 4, 32, 176, 223, 31, 133, 108, 84, 158, 102, 70, 11, 165, 175, 196, 12,
            201, 130, 25, 131, 46, 125, 156, 194, 28, 23, 55, 133, 157, 164, 135, 136, 220, 78, 48,
            37, 2, 1, 2, 4, 32, 190, 82, 180, 235, 222, 33, 79, 50, 152, 136, 142, 35, 116, 224, 6,
            242, 156, 141, 128, 248, 10, 61, 98, 86, 248, 45, 207, 210, 90, 232, 175, 38, 48, 37, 2,
            1, 3, 4, 32, 0, 194, 104, 108, 237, 246, 97, 230, 116, 198, 69, 110, 26, 87, 17, 89,
            110, 199, 108, 250, 36, 21, 39, 87, 110, 102, 250, 213, 174, 131, 171, 174, 48, 37, 2,
            1, 11, 4, 32, 136, 155, 87, 144, 111, 15, 152, 127, 85, 25, 154, 81, 20, 58, 51, 75,
            193, 116, 234, 0, 60, 30, 29, 30, 183, 141, 72, 247, 255, 203, 100, 124, 48, 37, 2, 1,
            12, 4, 32, 41, 234, 106, 78, 31, 11, 114, 137, 237, 17, 92, 71, 134, 47, 62, 78, 189,
            233, 201, 214, 53, 4, 47, 189, 201, 133, 6, 121, 34, 131, 64, 142, 48, 37, 2, 1, 13, 4,
            32, 91, 222, 210, 193, 62, 222, 104, 82, 36, 41, 138, 253, 70, 15, 148, 208, 156, 45,
            105, 171, 241, 195, 185, 43, 217, 162, 146, 201, 222, 89, 238, 38, 48, 37, 2, 1, 14, 4,
            32, 76, 123, 216, 13, 51, 227, 72, 245, 59, 193, 238, 166, 103, 49, 23, 164, 171, 188,
            194, 197, 156, 187, 249, 28, 198, 95, 69, 15, 182, 56, 54, 38, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ];
        let result = [
            32, 85, 108, 174, 127, 112, 178, 182, 8, 43, 134, 123, 192, 211, 131, 66, 184, 240, 212,
            181, 240, 180, 106, 195, 24, 117, 54, 129, 19, 10, 250, 53,
        ];
        let message_size = 297;
        assert_eq(sha256_var(input, message_size), result);
    }

    #[test]
    fn msg_big_no_padding() {
        let input = [
            48, 130, 1, 37, 2, 1, 0, 48, 11, 6, 9, 96, 134, 72, 1, 101, 3, 4, 2, 1, 48, 130, 1, 17,
            48, 37, 2, 1, 1, 4, 32, 176, 223, 31, 133, 108, 84, 158, 102, 70, 11, 165, 175, 196, 12,
            201, 130, 25, 131, 46, 125, 156, 194, 28, 23, 55, 133, 157, 164, 135, 136, 220, 78, 48,
            37, 2, 1, 2, 4, 32, 190, 82, 180, 235, 222, 33, 79, 50, 152, 136, 142, 35, 116, 224, 6,
            242, 156, 141, 128, 248, 10, 61, 98, 86, 248, 45, 207, 210, 90, 232, 175, 38, 48, 37, 2,
            1, 3, 4, 32, 0, 194, 104, 108, 237, 246, 97, 230, 116, 198, 69, 110, 26, 87, 17, 89,
            110, 199, 108, 250, 36, 21, 39, 87, 110, 102, 250, 213, 174, 131, 171, 174, 48, 37, 2,
            1, 11, 4, 32, 136, 155, 87, 144, 111, 15, 152, 127, 85, 25, 154, 81, 20, 58, 51, 75,
            193, 116, 234, 0, 60, 30, 29, 30, 183, 141, 72, 247, 255, 203, 100, 124, 48, 37, 2, 1,
            12, 4, 32, 41, 234, 106, 78, 31, 11, 114, 137, 237, 17, 92, 71, 134, 47, 62, 78, 189,
            233, 201, 214, 53, 4, 47, 189, 201, 133, 6, 121, 34, 131, 64, 142, 48, 37, 2, 1, 13, 4,
            32, 91, 222, 210, 193, 62, 222, 104, 82, 36, 41, 138, 253, 70, 15, 148, 208, 156, 45,
            105, 171, 241, 195, 185, 43, 217, 162, 146, 201, 222, 89, 238, 38, 48, 37, 2, 1, 14, 4,
            32, 76, 123, 216, 13, 51, 227, 72, 245, 59, 193, 238, 166, 103, 49, 23, 164, 171, 188,
            194, 197, 156, 187, 249, 28, 198, 95, 69, 15, 182, 56, 54, 38,
        ];
        let result = [
            32, 85, 108, 174, 127, 112, 178, 182, 8, 43, 134, 123, 192, 211, 131, 66, 184, 240, 212,
            181, 240, 180, 106, 195, 24, 117, 54, 129, 19, 10, 250, 53,
        ];
        assert_eq(sha256_var(input, input.len() as u64), result);
    }

    #[test]
    fn same_msg_len_variable_padding() {
        let input = [
            29, 81, 165, 84, 243, 114, 101, 37, 242, 146, 127, 99, 69, 145, 39, 72, 213, 39, 253,
            179, 218, 37, 217, 201, 172, 93, 198, 50, 249, 70, 15, 30, 162, 112, 187, 40, 140, 9,
            236, 53, 32, 44, 38, 163, 113, 254, 192, 197, 44, 89, 71, 130, 169, 242, 17, 211, 214,
            72, 19, 178, 186, 168, 147, 127, 99, 101, 252, 227, 8, 147, 150, 85, 97, 158, 17, 107,
            218, 244, 82, 113, 247, 91, 208, 214, 60, 244, 87, 137, 173, 201, 130, 18, 66, 56, 198,
            149, 207, 189, 175, 120, 123, 224, 177, 167, 251, 159, 143, 110, 68, 183, 189, 70, 126,
            32, 35, 164, 44, 30, 44, 12, 65, 18, 62, 239, 242, 2, 248, 104, 2, 178, 64, 28, 126, 36,
            137, 24, 14, 116, 91, 98, 90, 159, 218, 102, 45, 11, 110, 223, 245, 184, 52, 99, 59,
            245, 136, 175, 3, 72, 164, 146, 145, 116, 22, 66, 24, 49, 193, 121, 3, 60, 37, 41, 97,
            3, 190, 66, 195, 225, 63, 46, 3, 118, 4, 208, 15, 1, 40, 254, 235, 151, 123, 70, 180,
            170, 44, 172, 90, 4, 254, 53, 239, 116, 246, 67, 56, 129, 61, 22, 169, 213, 65, 27, 216,
            116, 162, 239, 214, 207, 126, 177, 20, 100, 25, 48, 143, 84, 215, 70, 197, 53, 65, 70,
            86, 172, 61, 62, 9, 212, 167, 169, 133, 41, 126, 213, 196, 33, 192, 238, 0, 63, 246,
            215, 58, 128, 110, 101, 92, 3, 170, 214, 130, 149, 52, 81, 125, 118, 233, 3, 118, 193,
            104, 207, 120, 115, 77, 253, 191, 122, 0, 107, 164, 207, 113, 81, 169, 36, 201, 228, 74,
            134, 131, 218, 178, 35, 30, 216, 101, 2, 103, 174, 87, 95, 50, 50, 215, 157, 5, 210,
            188, 54, 211, 78, 45, 199, 96, 121, 241, 241, 176, 226, 194, 134, 130, 89, 217, 210,
            186, 32, 140, 39, 91, 103, 212, 26, 87, 32, 72, 144, 228, 230, 117, 99, 188, 50, 15, 69,
            79, 179, 50, 12, 106, 86, 218, 101, 73, 142, 243, 29, 250, 122, 228, 233, 29, 255, 22,
            121, 114, 125, 103, 41, 250, 241, 179, 126, 158, 198, 116, 209, 65, 94, 98, 228, 175,
            169, 96, 3, 9, 233, 133, 214, 55, 161, 164, 103, 80, 85, 24, 186, 64, 167, 92, 131, 53,
            101, 202, 47, 25, 104, 118, 155, 14, 12, 12, 25, 116, 45, 221, 249, 28, 246, 212, 200,
            157, 167, 169, 56, 197, 181, 4, 245, 146, 1, 140, 234, 191, 212, 228, 125, 87, 81, 86,
            119, 30, 63, 129, 143, 32, 96,
        ];

        // Prepare inputs of different lengths
        let mut input_511 = [0; 511];
        let mut input_512 = [0; 512]; // Next block
        let mut input_575 = [0; 575];
        let mut input_576 = [0; 576]; // Next block
        for i in 0..input.len() {
            input_511[i] = input[i];
            input_512[i] = input[i];
            input_575[i] = input[i];
            input_576[i] = input[i];
        }

        // Compute hashes of all inputs (with same message length)
        let fixed_length_hash = super::sha256(input);
        let var_full_length_hash = sha256_var(input, input.len() as u64);
        let var_length_hash_511 = sha256_var(input_511, input.len() as u64);
        let var_length_hash_512 = sha256_var(input_512, input.len() as u64);
        let var_length_hash_575 = sha256_var(input_575, input.len() as u64);
        let var_length_hash_576 = sha256_var(input_576, input.len() as u64);

        // All of the above should have produced the same hash
        assert_eq(var_full_length_hash, fixed_length_hash);
        assert_eq(var_length_hash_511, fixed_length_hash);
        assert_eq(var_length_hash_512, fixed_length_hash);
        assert_eq(var_length_hash_575, fixed_length_hash);
        assert_eq(var_length_hash_576, fixed_length_hash);
    }
}
