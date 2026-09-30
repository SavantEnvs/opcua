// Behavioral oracle for mayhem/test.sh (SPEC §6.3): a known-input -> known-output round trip
// through opcua's OWN Variant binary codec, the same code path fuzz_deserialize exercises.
// A no-op / exit(0) neutering of the library makes these assertions fail.
//
// This exists as its own crate (rather than `cargo test -p opcua`) because the "opcua" crate's
// dev-dependency `rustc-serialize 0.3.24` (unmaintained since ~2016) does not compile under any
// modern rustc (E0310, a real soundness hole closed since): building any test binary for the
// whole crate is impossible on this toolchain regardless of which tests are filtered at runtime.
use opcua::types::{BinaryEncoder, DecodingOptions, Variant};
use std::io::Cursor;

fn main() {
    // Known input: OPC UA binary Variant encoding of Int32(42) — mask byte 0x06 (DataTypeId::Int32)
    // followed by the little-endian i32 payload.
    const KNOWN_BYTES: [u8; 5] = [0x06, 0x2A, 0x00, 0x00, 0x00];

    let value = Variant::Int32(42);
    let encoded = value.encode_to_vec();
    assert_eq!(
        encoded, KNOWN_BYTES,
        "Variant::Int32(42) must encode to the known OPC UA wire bytes"
    );

    let decoding_options = DecodingOptions::default();
    let mut stream = Cursor::new(&KNOWN_BYTES[..]);
    let decoded = Variant::decode(&mut stream, &decoding_options).expect("decode failed");
    match decoded {
        Variant::Int32(v) => assert_eq!(v, 42, "known wire bytes must decode back to Int32(42)"),
        other => panic!("expected Variant::Int32(42), got {:?}", other),
    }

    println!("opcua-oracle: known-input/known-output Variant round trip OK");
}
