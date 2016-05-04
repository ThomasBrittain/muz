(* MySql database functions *)

open Mysql

let (>>=) = Lwt.bind

(* User type *)
type user = {
  username : string option;
  email    : string option;
  verified : bool option
}

(* TODO: Add a locaiton to the story. Maybe a school would be useful also. *)
(* TODO: Add a story id for easy identification of stories *)
(* Story type *)
type story = {
  title     : string;
  body      : string;
  author    : string;
  pic_link  : string option;
  date_time : string;
  hashtags : string list;
}

(* Database *)
let user_db = {
  dbhost = None;
  dbname = Some "muz";
  dbport = Some 3306;
  dbpwd = Some "HPMpRjbvWMe49A95xHsFhRyw";
  dbuser = Some "btc_admin_4A3f8E";
  dbsocket = None
}

module Config =
  struct
    (* Number of iterations for password encryption *)
    let pwd_iter_count = 12
  end

let string_of_option so =
  match so with
  | Some s -> s
  | None -> ""

let pic_link_of_option s =
  match s with
  | "" -> None
  | _ -> Some s

let sll_of_res res =
  Mysql.map res (fun a -> Array.to_list a)
  |> List.map (List.map string_of_option)

let sl_of_csv s =
  Str.split (Str.regexp "[,]") s

let story_of_result sl =
  {title = List.nth sl 2;
   body = List.nth sl 3;
   author = List.nth sl 1;
   pic_link = pic_link_of_option @@ List.nth sl 4;
   date_time = List.nth sl 5;
   hashtags = sl_of_csv (List.nth sl 6)
  }

(* Check if the username already exists in database *)
let username_exists new_username =
  let conn = connect user_db in
  let sql_stmt =
    "SELECT username FROM muz.users WHERE username = '" ^
    (real_escape conn new_username) ^ "'"
  in
  let query_result = exec conn sql_stmt in
  disconnect conn
  |> fun () -> if (size query_result) = Int64.zero then Lwt.return false else Lwt.return true

(* Check if the email_address already exists in the database *)
let email_exists new_email =
  let conn = connect user_db in
  let sql_stmt =
    "SELECT email FROM muz.users WHERE email = '" ^ (real_escape conn new_email) ^ "'"
  in
  let query_result = exec conn sql_stmt in
  disconnect conn
  |> fun () -> if (size query_result) = Int64.zero then Lwt.return false else Lwt.return true

(* Check that a password meets complexity requirements *)
let pwd_req_check pwd =

   (* At least 8 characters *)
   let length_check = if String.length pwd >= 8 then true else false in
   let length_msg =
     if length_check
     then ""
     else "The password must contain at least 8 characters."
   in
   (* At least 1 uppercase letter *)
   let uppercase_check =
     try (Str.search_forward (Str.regexp "[A-Z]") pwd 0) >= 0 with
     | Not_found -> false
   in
   let uppercase_msg =
     if uppercase_check
     then ""
     else "The password must contain at lease 1 uppercase character."
   in
   (* At least 3 numbers *)
   let number_check =
     Str.bounded_full_split (Str.regexp "[0-9]") pwd 0
     |> List.filter (fun x -> match x with Str.Delim _ -> true | _ -> false)
     |> List.length >= 3
   in
   let number_msg =
     if number_check
     then ""
     else "The password must contain at least 3 numbers."
   in
   (* Less than 100 characters *)
   let max_len_check = if String.length pwd <= 100 then true else false in
   let max_len_msg =
     if max_len_check
     then ""
     else "The password length must not contain more than 100 characters."
   in
   (* No Spaces Allowed *)
   let spaces_check =
     try if (Str.search_forward (Str.regexp " ") pwd 0) >= 0 then false else true with
     | Not_found -> true
   in
   let spaces_msg =
     if spaces_check
     then ""
     else "The password cannot contain any spaces."
   in

   match length_check, uppercase_check, number_check, max_len_check, spaces_check with
   | true, true, true, true, true -> true, ""
   | _, _, _, _, _ ->
       false, ("Error: " ^ length_msg ^ uppercase_msg ^ number_msg ^ max_len_msg ^ spaces_msg)

(* Connect, write a new user to the a database and disconnect *)
let write_new_user (u : user) pwd =
  match u.username with
  | Some un ->
      (
        let conn = connect user_db in
        let esc s = Mysql.real_escape conn s in
        username_exists un
        >>= fun b ->
          (
            if b then (disconnect conn |> fun () -> Lwt.return @@ "Username already exists")
            else
              let g = string_of_option in
              (* Salt and hash the password before storing *)
              let pwd' =
                Bcrypt.hash ~count:Config.pwd_iter_count (esc pwd) |> Bcrypt.string_of_hash
              in
              let sql_stmt =
                "INSERT INTO muz.users (username, email, password)" ^
                " VALUES('" ^ (esc @@ g u.username) ^ "', '" ^ (esc @@ g u.email) ^ "', '" ^
                (esc pwd') ^ "')"
              in
              let _ = exec conn sql_stmt in
              disconnect conn |> fun () -> Lwt.return "Username successfully created"
          )
      )
  | None -> Lwt.return "No username found"

(* Verify a username and password pair *)
let verify_login username pwd =
  let conn = connect user_db in
  let esc s = Mysql.real_escape conn s in
  let sql_stmt =
    "SELECT username, password FROM muz.users WHERE username = '" ^ (esc username) ^"'"
  in
  let query_result = exec conn sql_stmt in
  let name_pass =
    try query_result |> sll_of_res |> List.hd
    with Failure hd -> ["username fail"; "password fail"]
  in
  let verified =
    try
      List.nth name_pass 0 = username &&
      Bcrypt.verify (esc pwd) (Bcrypt.hash_of_string @@ esc @@ List.nth name_pass 1)
    with Bcrypt.Bcrypt_error -> false
  in
  disconnect conn;
  Lwt.return verified

(* Clean a users string of hashtags into a csv to be stored in the db *)
let csv_of_hashtags hashtags =
  Str.split (Str.regexp "[#]") hashtags
  |> List.map (fun s -> Str.global_replace (Str.regexp "[ ]") "" s)
  |> List.filter (fun s -> s <> "")
  |> String.concat ","

(* Write a new story to the database *)
let write_new_story (u : user) ~title ~body ~pic_link ~hashtags =
  let now = string_of_int @@ int_of_float @@ Unix.time () in
  let conn = connect user_db in
  let esc s = Mysql.real_escape conn s in
  let sql_stmt =
    "INSERT INTO muz.stories (username, title, body, pic_link, date_time, hashtags)" ^
    " VALUES ('" ^
    (esc @@ string_of_option u.username) ^ "', '" ^ (esc title) ^ "', '" ^ (esc body) ^ "', '" ^
    (esc @@ string_of_option pic_link) ^ "', '" ^ (esc now) ^ "', '" ^
    (esc @@ csv_of_hashtags hashtags) ^ "')"
  in
  let _ = exec conn sql_stmt in
  Lwt.return @@ disconnect conn

(* Get the most recent story from the database *)
let get_newest_story () =
  let conn = connect user_db in
  let sql_stmt_1 = "SELECT MAX(story_id) FROM muz.stories" in
  let query_result_1 = exec conn sql_stmt_1 in
  let max_id = query_result_1 |> sll_of_res |> List.hd |> List.hd in
  let sql_stmt_2 = "SELECT * FROM muz.stories WHERE story_id = " ^ max_id in
  let res = exec conn sql_stmt_2 |> sll_of_res |> List.hd in
  Lwt.return @@ story_of_result res

(* Get a stories for a single user *)
let get_all_stories username =
  let conn = connect user_db in
  let esc s = Mysql.real_escape conn s in
  let sql_stmt = "SELECT * FROM muz.stories WHERE username = " ^ "'" ^ (esc @@ username) ^ "'" in
  let query_result = exec conn sql_stmt in
  disconnect conn;
  try query_result |> sll_of_res |> (List.map story_of_result)
  with Failure hd -> []

(* Get the most recent stories *)
let get_recent_stories ~n () =
  let conn = connect user_db in
  let sql_stmt = "SELECT * FROM muz.stories ORDER BY date_time DESC LIMIT " ^ (string_of_int n) in
  let query_result = exec conn sql_stmt in
  disconnect conn;
  Lwt.return (
    try query_result |> sll_of_res |> (List.map story_of_result)
    with Failure hd -> []
  )

(* Given a csv of hashtags, sort the list by the highest count *)
let rec sort_tags ?(sorted_tags = []) (tag_list : string list) =
  match tag_list with
  | [] -> List.rev @@ List.sort (fun x y -> compare (snd x) (snd y)) sorted_tags
  | _ ->
    let new_tag = List.hd tag_list in
    let new_tag_count = List.filter (fun x -> x = new_tag) tag_list |> List.length in
    let remaining_list = List.filter (fun x -> x <> new_tag) tag_list in
    sort_tags ~sorted_tags:((new_tag, new_tag_count) :: sorted_tags) remaining_list

(* Get n elements from a list *)
let rec get_n ?(l_out = []) ~n l =
  match l with
  | [] -> List.rev l_out
  | hd :: tl ->
    if List.length l_out < n
    then get_n ~l_out:(hd :: l_out) ~n tl
    else List.rev l_out

(* Get hashtags for all stories in the last 24 hours *)
let get_recent_hashtags ~n () =
  let conn = connect user_db in
  let now = int_of_float @@ Unix.time () in
  let one_day_ago = string_of_int @@ now - 86400 in
  let sql_stmt =
    "SELECT hashtags FROM muz.stories WHERE date_time > " ^ one_day_ago ^
    " ORDER BY date_time DESC"
  in
  let query_result = exec conn sql_stmt in
  disconnect conn;
  let csv_tags =
    (try query_result |> sll_of_res |> List.map (List.hd) |> List.fold_left (^) ""
    with Failure hd -> "")
  in
  let sl_tags = Str.split (Str.regexp "[,]") csv_tags in
  Lwt.return (sort_tags sl_tags |> List.map (fun (s, i) -> s) |> get_n ~n)

(* Get all stories with a specific hashtag - Limit to 100 *)
let get_stories_by_hashtag hashtag =
  let conn = connect user_db in
  let sql_stmt = "SELECT * FROM muz.stories WHERE hashtags LIKE '%" ^ hashtag ^ "%'" in
  let query_result = exec conn sql_stmt in
  disconnect conn;
  try query_result |> sll_of_res |> (List.map story_of_result)
  with Failure hd -> []
