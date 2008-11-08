open Source
open Dtools
open Theora

(** Output in a ogg theora *)

let create_streams ~quality ~vorbis_quality =
  let create_encoder ogg_enc metadata =
    let enc = 
      Theora_format.create_encoder 
        ~quality ~metadata () 
    in
    Ogg_encoder.register_track ogg_enc enc
  in
  let encode =
    Ogg_output.encode_video ()
  in
  let l = ["theora",(create_encoder,encode)] in
  if vorbis_quality > 0. then
    let freq = Fmt.samples_per_second () in
    let stereo = (Fmt.channels ()) > 1 in
    ("vorbis",
     Vorbis_encoded.create 
       ~quality:vorbis_quality ~bitrate:(0,0,0)
       ~mode:Vorbis_encoded.VBR freq stereo)::l
  else
    l
               

let theora_proto = 
     [
      "quality",
      Lang.int_t,
      Some (Lang.int 100),
      Some "Quality setting for theora encoding." ;

      "vorbis_quality",
      Lang.float_t,
      Some (Lang.float 2.),
      Some "Quality setting for vorbis encoding. \
            Don't encode audio if value is negative or null." ;

     ] @ (Ogg_output.ogg_proto true)


let () =
  Lang.add_operator "output.file.theora"
    ([       
        "start",
         Lang.bool_t, Some (Lang.bool true),
         Some "Start output threads on operator initialization." ] @ 
      theora_proto @ File_output.proto @ ["", Lang.source_t, None, None ])
    ~category:Lang.Output
    ~descr:"Output the source's stream as an ogg/theora file."
    (fun p ->
       let e f v = f (List.assoc v p) in
       let quality = e Lang.to_int "quality" in
       let vorbis_quality = e Lang.to_float "vorbis_quality" in
       let autostart = e Lang.to_bool "start" in
       let skeleton = e Lang.to_bool "skeleton" in
       let filename = Lang.to_string (Lang.assoc "" 1 p) in
       let source = Lang.assoc "" 2 p in
       let append = Lang.to_bool (List.assoc "append" p) in
       let perm = Lang.to_int (List.assoc "perm" p) in
       let dir_perm = Lang.to_int (List.assoc "dir_perm" p) in
       let reload_predicate = List.assoc "reopen_when" p in
       let reload_delay = Lang.to_float (List.assoc "reopen_delay" p) in
       let reload_on_metadata =
         Lang.to_bool (List.assoc "reopen_on_metadata" p)
       in
       let streams = create_streams ~quality ~vorbis_quality in
         ((new Ogg_output.to_file 
             filename ~streams
             ~append ~perm ~dir_perm ~skeleton
             ~reload_delay ~reload_predicate ~reload_on_metadata
             ~autostart source):>source))

