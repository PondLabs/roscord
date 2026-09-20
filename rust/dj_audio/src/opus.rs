//! Opus for symphonia, decoded by the pure-Rust `opus-rs`.
//!
//! symphonia reads WebM and Ogg but ships no Opus decoder, and the booth
//! wants one: YouTube's best audio is Opus (itag 251, about 130 kbps at
//! 48 kHz), which keeps the treble its 130 kbps AAC throws away.
//!
//! Two things happen here that `opus-rs` is not trusted to do itself. Both
//! were measured against libopus on a real song:
//!
//! - **Framing.** A packet may carry several frames (RFC 6716 §3.2). They
//!   are split out here and handed over one at a time as code 0 packets,
//!   because `opus-rs` mis-reads some code 3 frame lengths: 12 of the 3551
//!   packets of a 60 ms encode, each failure losing 60 ms of the song.
//! - **Mode.** `opus-rs` decodes CELT to within 82 dB of libopus, but SILK
//!   only to 15 dB and hybrid to 61 dB. Music at the bitrates the booth
//!   downloads is CELT from end to end, so a SILK or hybrid packet means
//!   the file is not what we took it for: it is refused rather than played
//!   wrong.

use symphonia::core::audio::{
    AsGenericAudioBufferRef, AudioBuffer, AudioMut, AudioSpec, Channels, GenericAudioBufferRef,
    Position,
};
use symphonia::core::codecs::CodecInfo;
use symphonia::core::codecs::audio::well_known::CODEC_ID_OPUS;
use symphonia::core::codecs::audio::{
    AudioCodecParameters, AudioDecoder, AudioDecoderOptions, FinalizeResult,
};
use symphonia::core::codecs::registry::{RegisterableAudioDecoder, SupportedAudioCodec};
use symphonia::core::errors::{Result, decode_error, unsupported_error};
use symphonia::core::packet::PacketRef;

/// Opus is always decoded at 48 kHz, which is the booth's output rate too.
const RATE: u32 = 48_000;
/// 120 ms: the most one packet can hold, and the most frames in one.
const MAX_FRAMES: usize = 5760;
const MAX_FRAMES_PER_PACKET: usize = 48;
/// The most bytes one packet may hold (RFC 6716 §3.4).
const MAX_OPUS_PACKET: usize = 1275 * MAX_FRAMES_PER_PACKET;
/// Configs below this one use SILK, alone or together with CELT.
const FIRST_CELT_CONFIG: u8 = 16;

/// An Opus packet's frames, as `(start, end)` in the packet (RFC 6716 §3.2).
///
/// Pulled out of the decoder so it can be tested on its own: this is the
/// part `opus-rs` gets wrong.
pub(crate) fn split_frames(packet: &[u8], frames: &mut Vec<(usize, usize)>) -> Result<()> {
    frames.clear();
    if packet.is_empty() {
        return decode_error("opus: empty packet");
    }
    // Offsets, so the caller keeps the packet to itself.
    let at = |slice: &[u8]| slice.as_ptr() as usize - packet.as_ptr() as usize;
    let push = |body: &[u8], frames: &mut Vec<(usize, usize)>| {
        let start = at(body);
        frames.push((start, start + body.len()));
    };

    let (&toc, body) = packet.split_first().expect("not empty");
    match toc & 0x03 {
        0 => push(body, frames),
        1 => {
            if body.len() % 2 != 0 {
                return decode_error("opus: code 1 packet of odd length");
            }
            let (first, second) = body.split_at(body.len() / 2);
            push(first, frames);
            push(second, frames);
        }
        2 => {
            let (len, rest) = read_length(body)?;
            if len > rest.len() {
                return decode_error("opus: code 2 frame runs past the packet");
            }
            let (first, second) = rest.split_at(len);
            push(first, frames);
            push(second, frames);
        }
        _ => {
            let Some((&head, mut rest)) = body.split_first() else {
                return decode_error("opus: code 3 packet without a frame count");
            };
            let count = (head & 0x3F) as usize;
            if count == 0 || count > MAX_FRAMES_PER_PACKET {
                return decode_error("opus: code 3 packet with a bad frame count");
            }
            // No packet may hold more than 120 ms, which is also what the
            // decoder's output buffer is sized for.
            if count * samples_per_frame(toc) > MAX_FRAMES {
                return decode_error("opus: code 3 packet longer than 120 ms");
            }
            // Padding sits at the end, but says how long it is here, as a
            // run of bytes where 255 means "254 and the count goes on".
            if head & 0x40 != 0 {
                let mut padding = 0usize;
                loop {
                    let Some((&byte, tail)) = rest.split_first() else {
                        return decode_error("opus: code 3 padding count runs past the packet");
                    };
                    rest = tail;
                    if byte == 255 {
                        padding += 254;
                    } else {
                        padding += byte as usize;
                        break;
                    }
                }
                if padding > rest.len() {
                    return decode_error("opus: code 3 padding runs past the packet");
                }
                rest = &rest[..rest.len() - padding];
            }
            if head & 0x80 != 0 {
                // The lengths of every frame but the last come first, all
                // together; the frames themselves follow. Reading a length
                // and then its frame, turn by turn, is the mistake that
                // makes `opus-rs` lose packets.
                let mut lengths = [0usize; MAX_FRAMES_PER_PACKET];
                let mut total = 0usize;
                for length in lengths.iter_mut().take(count - 1) {
                    let (len, tail) = read_length(rest)?;
                    *length = len;
                    total += len;
                    rest = tail;
                }
                if total > rest.len() {
                    return decode_error("opus: code 3 frames run past the packet");
                }
                for &len in lengths.iter().take(count - 1) {
                    let (frame, tail) = rest.split_at(len);
                    push(frame, frames);
                    rest = tail;
                }
                push(rest, frames);
            } else {
                if rest.len() % count != 0 {
                    return decode_error("opus: code 3 frames of unequal length");
                }
                let len = rest.len() / count;
                for i in 0..count {
                    push(&rest[i * len..(i + 1) * len], frames);
                }
            }
        }
    }
    Ok(())
}

/// Samples per frame, at 48 kHz, for a packet's config (RFC 6716 §3.1).
fn samples_per_frame(toc: u8) -> usize {
    let config = toc >> 3;
    let sizes: [usize; 4] = match config {
        // SILK: 10, 20, 40 or 60 ms.
        0..=11 => [480, 960, 1920, 2880],
        // Hybrid: 10 or 20 ms, and the config only picks between two.
        12..=15 => [480, 960, 480, 960],
        // CELT: 2.5, 5, 10 or 20 ms.
        _ => [120, 240, 480, 960],
    };
    let index = if (12..16).contains(&config) { config % 2 } else { config % 4 };
    sizes[index as usize]
}

/// A frame length: one byte under 252, otherwise two (RFC 6716 §3.1).
fn read_length(data: &[u8]) -> Result<(usize, &[u8])> {
    let Some((&first, rest)) = data.split_first() else {
        return decode_error("opus: missing frame length");
    };
    if first < 252 {
        return Ok((first as usize, rest));
    }
    let Some((&second, rest)) = rest.split_first() else {
        return decode_error("opus: truncated frame length");
    };
    Ok((first as usize + second as usize * 4, rest))
}

/// The head of an Opus stream (RFC 7845 §5.1), as the container carries it.
///
/// Its pre-skip — the samples the encoder needs before its output means
/// anything — is deliberately not read here. Both containers the booth
/// meets already account for it on the track's own timeline, and dropping
/// it a second time would take 6 ms off the front of every song: WebM
/// starts the first packet at a negative time, Ogg reports it as the
/// track's delay (see `source::make_decoder`).
struct OpusHead {
    channels: usize,
    /// Fixed gain, already turned into a factor.
    gain: f32,
}

impl OpusHead {
    fn parse(data: &[u8]) -> Result<Self> {
        if data.len() < 19 || &data[..8] != b"OpusHead" {
            return unsupported_error("opus: no OpusHead");
        }
        // Only version 0 is defined, and readers must accept any major 0.
        if data[8] >> 4 != 0 {
            return unsupported_error("opus: unknown OpusHead version");
        }
        let channels = data[9] as usize;
        if !(1..=2).contains(&channels) {
            return unsupported_error("opus: more than two channels");
        }
        // Family 0 is plain mono or stereo; the others are multistream,
        // which this decoder does not take apart.
        if data[18] != 0 {
            return unsupported_error("opus: multistream channel mapping");
        }
        let gain_db = i16::from_le_bytes([data[16], data[17]]) as f32 / 256.0;
        Ok(OpusHead { channels, gain: 10f32.powf(gain_db / 20.0) })
    }
}

pub struct OpusDecoder {
    params: AudioCodecParameters,
    decoder: opus_rs::OpusDecoder,
    channels: usize,
    gain: f32,
    buf: AudioBuffer<f32>,
    /// One frame, interleaved, as `opus-rs` writes it.
    frame: Vec<f32>,
    /// One frame with a code 0 header in front, as it is handed over.
    one: Vec<u8>,
    /// The whole packet, interleaved, before it is put into planes.
    packet: Vec<f32>,
    ranges: Vec<(usize, usize)>,
}

const CODEC: SupportedAudioCodec = SupportedAudioCodec {
    id: CODEC_ID_OPUS,
    info: CodecInfo { short_name: "opus", long_name: "Opus", profiles: &[] },
};

impl OpusDecoder {
    pub fn try_new(params: &AudioCodecParameters, _opts: &AudioDecoderOptions) -> Result<Self> {
        if params.codec != CODEC_ID_OPUS {
            return unsupported_error("opus: not an Opus track");
        }
        let head = match params.extra_data.as_deref() {
            Some(data) => OpusHead::parse(data)?,
            // Every container the booth reads carries the head, and it is
            // the only place the channel count and gain come from.
            None => return unsupported_error("opus: no codec header"),
        };
        let decoder = opus_rs::OpusDecoder::new(RATE as i32, head.channels)
            .map_err(|_| symphonia::core::errors::Error::Unsupported("opus: no decoder"))?;
        let layout = Channels::Positioned(if head.channels == 1 {
            Position::FRONT_LEFT
        } else {
            Position::FRONT_LEFT | Position::FRONT_RIGHT
        });
        let spec = AudioSpec::new(RATE, layout);
        Ok(OpusDecoder {
            params: params.clone(),
            decoder,
            channels: head.channels,
            gain: head.gain,
            buf: AudioBuffer::new(spec, MAX_FRAMES),
            frame: vec![0.0; MAX_FRAMES * head.channels],
            one: Vec::with_capacity(1 + MAX_OPUS_PACKET),
            packet: Vec::with_capacity(MAX_FRAMES * head.channels),
            ranges: Vec::with_capacity(MAX_FRAMES_PER_PACKET),
        })
    }

    fn decode_inner(&mut self, packet: &PacketRef<'_>) -> Result<()> {
        let data = packet.data;
        split_frames(data, &mut self.ranges)?;
        let toc = data[0];
        if toc >> 3 < FIRST_CELT_CONFIG {
            // See the note at the top: this decoder is only trusted with
            // CELT, and music at the booth's bitrates is nothing else.
            return unsupported_error("opus: SILK and hybrid streams are not supported");
        }
        // Opus lets a stream change how many channels it codes from packet
        // to packet; `opus-rs` does not, and turns those packets down one
        // by one. Every encoder the booth meets holds the count steady, so
        // one that does not is called unplayable here rather than left to
        // come out full of 20 ms holes.
        if usize::from((toc >> 2) & 1) + 1 != self.channels {
            return unsupported_error("opus: the packet's channels are not the stream's");
        }
        // A packet's frames all carry the TOC's config, so each one goes
        // over as a packet holding a single frame (code 0).
        let head = toc & 0xFC;

        self.packet.clear();
        for i in 0..self.ranges.len() {
            let (start, end) = self.ranges[i];
            self.one.clear();
            self.one.push(head);
            self.one.extend_from_slice(&data[start..end]);
            let frames = self
                .decoder
                .decode(&self.one, MAX_FRAMES, &mut self.frame)
                .map_err(|_| symphonia::core::errors::Error::DecodeError("opus: bad frame"))?;
            self.packet
                .extend_from_slice(&self.frame[..frames * self.channels]);
        }

        let frames = self.packet.len() / self.channels;
        let interleaved = &self.packet[..];

        self.buf.clear();
        self.buf.render_uninit(Some(frames));
        for channel in 0..self.channels {
            let plane = match self.buf.plane_mut(channel) {
                Some(plane) => plane,
                None => return decode_error("opus: missing audio plane"),
            };
            for (frame, sample) in plane.iter_mut().enumerate() {
                *sample = interleaved[frame * self.channels + channel] * self.gain;
            }
        }
        Ok(())
    }
}

impl AudioDecoder for OpusDecoder {
    fn reset(&mut self) {
        // Opus carries no state a seek can keep: start again.
        if let Ok(decoder) = opus_rs::OpusDecoder::new(RATE as i32, self.channels) {
            self.decoder = decoder;
        }
    }

    fn codec_info(&self) -> &CodecInfo {
        &CODEC.info
    }

    fn codec_params(&self) -> &AudioCodecParameters {
        &self.params
    }

    fn decode_ref(&mut self, packet: &PacketRef<'_>) -> Result<GenericAudioBufferRef<'_>> {
        match self.decode_inner(packet) {
            Ok(()) => Ok(self.buf.as_generic_audio_buffer_ref()),
            Err(e) => {
                self.buf.clear();
                Err(e)
            }
        }
    }

    fn finalize(&mut self) -> FinalizeResult {
        Default::default()
    }

    fn last_decoded(&self) -> GenericAudioBufferRef<'_> {
        self.buf.as_generic_audio_buffer_ref()
    }
}

impl RegisterableAudioDecoder for OpusDecoder {
    fn try_registry_new(
        params: &AudioCodecParameters,
        opts: &AudioDecoderOptions,
    ) -> Result<Box<dyn AudioDecoder>> {
        Ok(Box::new(OpusDecoder::try_new(params, opts)?))
    }

    fn supported_codecs() -> &'static [SupportedAudioCodec] {
        &[CODEC]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A code 0 packet: TOC then one frame.
    fn code0() -> Vec<u8> {
        let mut p = vec![0xFC]; // config 31, stereo, code 0
        p.extend_from_slice(&[1, 2, 3, 4]);
        p
    }

    fn split(packet: &[u8]) -> Result<Vec<Vec<u8>>> {
        let mut ranges = Vec::new();
        split_frames(packet, &mut ranges)?;
        Ok(ranges
            .into_iter()
            .map(|(s, e)| packet[s..e].to_vec())
            .collect())
    }

    #[test]
    fn code_0_is_one_frame() {
        assert_eq!(split(&code0()).unwrap(), vec![vec![1, 2, 3, 4]]);
    }

    #[test]
    fn code_1_is_two_halves() {
        let packet = [0xFD, 1, 2, 3, 4];
        assert_eq!(split(&packet).unwrap(), vec![vec![1, 2], vec![3, 4]]);
        // An odd payload cannot be halved.
        assert!(split(&[0xFD, 1, 2, 3]).is_err());
    }

    #[test]
    fn code_2_takes_the_first_length_from_the_packet() {
        let packet = [0xFE, 2, 1, 2, 3, 4, 5];
        assert_eq!(split(&packet).unwrap(), vec![vec![1, 2], vec![3, 4, 5]]);
        // A length past the end is refused, not trusted.
        assert!(split(&[0xFE, 9, 1, 2]).is_err());
    }

    #[test]
    fn two_byte_lengths_are_read_as_one_number() {
        // 252 + 1 * 4 = 256 bytes in the first frame.
        let mut packet = vec![0xFE, 252, 1];
        packet.extend(std::iter::repeat_n(7u8, 256));
        packet.extend_from_slice(&[9, 9]);
        let frames = split(&packet).unwrap();
        assert_eq!(frames[0].len(), 256);
        assert_eq!(frames[1], vec![9, 9]);
    }

    #[test]
    fn code_3_cbr_splits_evenly() {
        // v=0, p=0, M=3, then 6 bytes.
        let packet = [0xFF, 3, 1, 2, 3, 4, 5, 6];
        assert_eq!(
            split(&packet).unwrap(),
            vec![vec![1, 2], vec![3, 4], vec![5, 6]]
        );
        // 7 bytes do not divide into 3 frames.
        assert!(split(&[0xFF, 3, 1, 2, 3, 4, 5, 6, 7]).is_err());
    }

    #[test]
    fn code_3_vbr_reads_every_length_but_the_last() {
        // v=1, M=3; lengths 1 and 2; the third frame is the remainder.
        let packet = [0xFF, 0x83, 1, 2, 10, 20, 21, 30, 31, 32];
        assert_eq!(
            split(&packet).unwrap(),
            vec![vec![10], vec![20, 21], vec![30, 31, 32]]
        );
    }

    #[test]
    fn code_3_vbr_lengths_past_the_packet_are_refused() {
        // v=1, M=3, lengths 9 and 9, but only 4 bytes of frames.
        assert!(split(&[0xFF, 0x83, 9, 9, 1, 2, 3, 4]).is_err());
    }

    #[test]
    fn code_3_padding_is_taken_off_the_end() {
        // v=0, p=1, M=2; 3 padding bytes; 4 bytes of frames.
        let packet = [0xFF, 0x42, 3, 1, 2, 3, 4, 0, 0, 0];
        assert_eq!(split(&packet).unwrap(), vec![vec![1, 2], vec![3, 4]]);
        // 255 means "254 so far, and the count goes on".
        let mut long = vec![0xFF, 0x42, 255, 1];
        long.extend_from_slice(&[1, 2, 3, 4]);
        long.extend(std::iter::repeat_n(0u8, 255));
        assert_eq!(split(&long).unwrap(), vec![vec![1, 2], vec![3, 4]]);
        // Padding longer than the packet is refused.
        assert!(split(&[0xFF, 0x42, 200, 1, 2]).is_err());
    }

    #[test]
    fn a_frame_count_of_zero_is_refused() {
        assert!(split(&[0xFF, 0x00]).is_err());
        // Over 48 frames is more than 120 ms, which Opus does not allow.
        assert!(split(&[0xFF, 49]).is_err());
    }

    #[test]
    fn a_packet_longer_than_120_ms_is_refused() {
        // Config 31 is 20 ms a frame, so seven of them is already too much.
        assert!(split(&[0xFF, 7, 1, 2, 3, 4, 5, 6, 7]).is_err());
        // Config 16 is 2.5 ms, so 48 frames fit in exactly 120 ms.
        let mut short = vec![0x80 | 0x03, 48];
        short.extend(std::iter::repeat_n(1u8, 48));
        assert_eq!(split(&short).unwrap().len(), 48);
    }

    #[test]
    fn frame_lengths_follow_the_config() {
        assert_eq!(samples_per_frame(31 << 3), 960); // CELT 20 ms
        assert_eq!(samples_per_frame(16 << 3), 120); // CELT 2.5 ms
        assert_eq!(samples_per_frame(13 << 3), 960); // hybrid 20 ms
        assert_eq!(samples_per_frame(12 << 3), 480); // hybrid 10 ms
        assert_eq!(samples_per_frame(3 << 3), 2880); // SILK 60 ms
    }

    #[test]
    fn an_empty_packet_is_refused() {
        assert!(split(&[]).is_err());
    }

    #[test]
    fn the_head_gives_channels_and_gain() {
        let mut head = b"OpusHead".to_vec();
        head.push(1); // version
        head.push(2); // channels
        head.extend_from_slice(&312u16.to_le_bytes()); // pre-skip
        head.extend_from_slice(&48_000u32.to_le_bytes()); // input rate
        head.extend_from_slice(&0i16.to_le_bytes()); // gain
        head.push(0); // mapping family
        let parsed = OpusHead::parse(&head).unwrap();
        assert_eq!(parsed.channels, 2);
        assert!((parsed.gain - 1.0).abs() < 1e-6);

        // -6.02 dB halves the samples.
        let mut quiet = head.clone();
        quiet[16..18].copy_from_slice(&(-1541i16).to_le_bytes());
        assert!((OpusHead::parse(&quiet).unwrap().gain - 0.5).abs() < 1e-3);
    }

    #[test]
    fn heads_this_decoder_cannot_honour_are_refused() {
        let mut head = b"OpusHead".to_vec();
        head.extend_from_slice(&[1, 2, 0x38, 1, 0x80, 0xBB, 0, 0, 0, 0, 0]);
        assert!(OpusHead::parse(&head).is_ok());
        // Multistream: the mapping family is the last byte.
        let mut multi = head.clone();
        multi[18] = 1;
        assert!(OpusHead::parse(&multi).is_err());
        // More than two channels.
        let mut six = head.clone();
        six[9] = 6;
        assert!(OpusHead::parse(&six).is_err());
        // Not a head at all.
        assert!(OpusHead::parse(b"not a head at all!!").is_err());
    }
}
