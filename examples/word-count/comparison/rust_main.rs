use std::collections::HashMap;
use std::fs::File;
use std::hint::black_box;
use std::io::{self, BufWriter, Read, Write};

const CHUNK_SIZE: usize = 32 * 1024;
const BATCH_SIZE: usize = 4096;
const CYCLES: usize = 32_768;

fn separator(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r' | b'\n')
}

fn add(counts: &mut HashMap<Vec<u8>, u64>, word: &[u8]) {
    if let Some(count) = counts.get_mut(word) {
        *count += 1;
    } else {
        counts.insert(word.to_vec(), 1);
    }
}

fn words(path: &std::ffi::OsStr) -> io::Result<()> {
    let mut file = File::open(path)?;
    let mut counts = HashMap::new();
    let mut carry = Vec::new();
    loop {
        let mut buffer = vec![0; CHUNK_SIZE];
        let amount = file.read(&mut buffer)?;
        if amount == 0 {
            if !carry.is_empty() {
                add(&mut counts, &carry);
            }
            break;
        }
        let chunk = &buffer[..amount];
        let mut start = 0;
        for (index, &byte) in chunk.iter().enumerate() {
            if !separator(byte) {
                continue;
            }
            let part = &chunk[start..index];
            if !carry.is_empty() {
                carry.extend_from_slice(part);
                add(&mut counts, &carry);
                carry.clear();
            } else if !part.is_empty() {
                add(&mut counts, part);
            }
            start = index + 1;
        }
        carry.extend_from_slice(&chunk[start..]);
    }
    let mut entries: Vec<_> = counts.iter().collect();
    entries.sort_unstable_by(|(left, _), (right, _)| left.cmp(right));
    let mut output = BufWriter::new(io::stdout().lock());
    for (word, count) in entries {
        output.write_all(word)?;
        writeln!(output, " {count}")?;
    }
    output.flush()
}

#[repr(C)]
struct Payload {
    id: u64,
    bytes: [u8; 56],
}

fn lifecycle() {
    let mut pointers = Vec::with_capacity(BATCH_SIZE);
    let mut sum = 0_u64;
    for cycle in 0..CYCLES {
        for index in 0..BATCH_SIZE {
            let id = (cycle * BATCH_SIZE + index) as u64;
            pointers.push(Box::new(Payload {
                id,
                bytes: [id as u8; 56],
            }));
        }
        for pointer in pointers.drain(..) {
            let payload = black_box(&*pointer);
            sum += payload.id + u64::from(payload.bytes[0]);
        }
    }
    println!("{sum}");
}

fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    match args.as_slice() {
        [_, mode] if mode == "lifecycle" => {
            lifecycle();
            Ok(())
        }
        [_, mode, path] if mode == "words" => words(path),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected words <file> or lifecycle",
        )),
    }
}
