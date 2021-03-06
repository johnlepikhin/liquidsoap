(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2017 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

open Source

module Generator = Generator.From_audio_video_plus
module Generated = Generated.From_audio_video_plus

type next_stop = [
  | `Metadata of Frame.metadata
  | `Break_and_metadata of Frame.metadata
  | `Break
  | `Sleep
  | `Nothing
]

type chunk = {
  sbuf: string;
  next: next_stop;
  mutable ofs: int;
  mutable len: int
}

class pipe ~kind ~process ~bufferize ~max ~restart ~restart_on_error (source:source) =
  (* We need a temporary log until the source has an id *)
  let log_ref = ref (fun _ -> ()) in
  let log = (fun x -> !log_ref x) in
  let log_error = ref (fun _ -> ()) in
  let sample_rate = Frame.audio_of_seconds 1. in
  let audio_src_rate = float sample_rate in
  let channels = (Frame.type_of_kind kind).Frame.audio in
  let abg_max_len = Frame.audio_of_seconds max in
  let converter =
    Rutils.create_from_iff ~format:`Wav ~channels ~samplesize:16
                           ~audio_src_rate
  in
  let header = 
    Wav_aiff.wav_header ~channels ~sample_rate
                        ~sample_size:16 ()
  in
  let on_start push =
    Process_handler.write header push;
    `Continue
  in
  let abg = Generator.create ~log ~kind `Audio in
  let on_stdout pull =
    let sbuf = Process_handler.read 1024 pull in
    let data = converter sbuf in
    let len = Array.length data.(0) in
    let buffered = Generator.length abg in
    Generator.put_audio abg data 0 (Array.length data.(0));
    if abg_max_len < buffered+len then
      `Delay (Frame.seconds_of_audio (buffered+len-abg_max_len))
    else
      `Continue
  in
  let on_stderr stderr =
    (!log_error) (Process_handler.read 1024 stderr);
    `Continue
  in
  let mutex = Mutex.create () in
  let next_stop = ref `Nothing in
  let on_stop = Tutils.mutexify mutex (fun e ->
    let ret = !next_stop in
    next_stop := `Nothing;
    match e, ret with
      | Some _ , _ -> restart_on_error
      | None, `Sleep -> false
      | None, `Break_and_metadata m ->
          Generator.add_metadata abg m;
          Generator.add_break abg;
          true
      | None, `Metadata m ->
          Generator.add_metadata abg m;
          true
      | None, `Break ->
          Generator.add_break abg;
          true
      | None, `Nothing -> restart)
  in
object(self)
  inherit source ~name:"pipe" kind
  inherit Generated.source abg ~empty_on_abort:false ~bufferize

  val mutable handler = None
  val to_write = Queue.create ()

  method stype = Source.Fallible

  method private get_handler =
    match handler with
      | Some h -> h
      | None -> raise Process_handler.Finished

  method private get_to_write =
    if source#is_ready then begin
      let tmp = Frame.create kind in
      source#get tmp;
      self#slave_tick;
      let buf = AFrame.content_of_type ~channels tmp 0 in
      let blen = Array.length buf.(0) in
      let slen_of_len len = 2 * len * Array.length buf in
      let slen = slen_of_len blen in
      let sbuf = Bytes.create slen in
      Audio.S16LE.of_audio buf 0 sbuf 0 blen;
      let metadata =
        List.sort (fun (pos,_) (pos',_) -> compare pos pos')
                  (Frame.get_all_metadata tmp)
      in
      let ofs = List.fold_left (fun ofs (pos, m) ->
        let pos = slen_of_len pos in
        let len = pos-ofs in
        let next =
          if pos = slen && (Frame.is_partial tmp) then
            `Break_and_metadata m
          else
            `Metadata m
        in
        Queue.push {sbuf;next;ofs;len} to_write;
        pos) 0 metadata
      in
      if ofs < slen then
        let len = slen-ofs in
        let next =
          if Frame.is_partial tmp then
            `Break
          else
            `Nothing
        in
        Queue.push {sbuf;next;ofs;len} to_write
    end

  method private on_stdin pusher =
    if Queue.is_empty to_write then self#get_to_write;
    try
      let ({sbuf;next;ofs;len} as chunk) = Queue.peek to_write in
      (* Select documentation: large write may still block.. *)
      let wlen = min 1024 len in
      let ret = pusher sbuf ofs wlen in
      if ret = len then begin
        Tutils.mutexify mutex (fun () -> next_stop := next) ();
        ignore(Queue.take to_write); 
        if next <> `Nothing then `Stop else `Continue
      end else begin
        chunk.ofs <- ofs+ret;
        chunk.len <- len-ret;
        `Continue
      end
    with Queue.Empty -> `Continue

  method private slave_tick =
    (Clock.get source#clock)#end_tick;
    source#after_output

  (* See smactross.ml for details. *)
  method private set_clock =
    let slave_clock = Clock.create_known (new Clock.clock self#id) in
    Clock.unify
      self#clock
      (Clock.create_unknown ~sources:[] ~sub_clocks:[slave_clock]) ;
    Clock.unify slave_clock source#clock ;
    Gc.finalise (fun self -> Clock.forget self#clock slave_clock) self

  method wake_up _ =
    source#get_ready [(self:>source)];
    (* Now we can create the log function *)
    log_ref := self#log#f 4 "%s";
    log_error := self#log#f 5 "%s";
    handler <- Some (Process_handler.run ~on_stop ~on_start ~on_stdout 
                                         ~on_stdin:self#on_stdin
                                         ~on_stderr ~log process)

  method abort_track = source#abort_track

  method sleep =
    Tutils.mutexify mutex (fun () ->
      try
        next_stop := `Sleep;
        Process_handler.stop self#get_handler;
        handler <- None
      with Process_handler.Finished -> ()) ()
end

let k = Lang.audio_any

let proto =
  [
    "process", Lang.string_t, None,
    Some "Process used to pipe data to.";

    "buffer", Lang.float_t, Some (Lang.float 1.),
    Some "Duration of the pre-buffered data." ;

    "max", Lang.float_t, Some (Lang.float 10.),
    Some "Maximum duration of the buffered data.";

    "restart", Lang.bool_t, Some (Lang.bool true),
    Some "Restart process when exited.";

    "restart_on_error", Lang.bool_t, Some (Lang.bool false),
    Some "Restart process when exited with error.";

    "", Lang.source_t (Lang.kind_type_of_kind_format ~fresh:2 k), None, None
    ]

let pipe p kind =
  let f v = List.assoc v p in
  let process, bufferize, max, restart, restart_on_error, src =
    Lang.to_string (f "process"),
    Lang.to_float (f "buffer"),
    Lang.to_float (f "max"),
    Lang.to_bool (f "restart"),
    Lang.to_bool (f "restart_on_error"),
    Lang.to_source (f "")
  in
  ((new pipe ~kind ~bufferize ~max ~restart ~restart_on_error ~process src):>source)

let () =
  Lang.add_operator "pipe" proto
    ~kind:k
    ~category:Lang.SoundProcessing
    ~descr:"Process audio signal through a given process stdin/stdout."
    pipe
