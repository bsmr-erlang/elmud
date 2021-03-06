defmodule Elmud do

require Dye
use Dye, func: true
require Amnesia
use Amnesia
use Database

## Version 0.0.1 of ElMUD : The MUD written in Elixir!###
## Now with a kv store for users! Should properly remove this at some point
## Now with a second persistent kv store using Amnesia!
## Going to add rooms!
## Now with user accounts with passwords and user account creation
## Addeded crash quick semantics to all receives and case, except for true, false cases

## set debug to true for verbose debugging and error output on server stdout, to false for almost no output on server stdout
def debug do true end

## Might just define Object struct in Database.ex
defmodule Object do

## this could probably be mad simpler
defstruct name: "Noname", title: "Notitle", description: "This object does not have a description", identifier: {:item, 0}, location: {:room, 0}, inventory: [], equipment: %{}, internal_verbs: [], external_verbs: [], internal_inventory_verbs: [], external_inventory_verbs: [], internal_equipment_verbs: [], external_equipment_verbs: []

end

## socket lookups a State_value
defmodule State_Value do

  defstruct pid: 0, name: ""

end

## Debug Output
defp douts(string) do
  if debug do IO.puts(string) end
end

## Debug Output but for use in a |> pipeline
defp dpass(string) do
  if debug do IO.puts("#{inspect string}") end
  string
end

def fst({item,_}) do item end

def snd({_,item}) do item end

## Initializes everything and starts the main loop_acceptor
def start(port) do
  douts "Starting Amnesia...."
  Amnesia.start
  douts "Database is UP!"
  password_filename = ".passwords"
  password_map = read_passwords_file password_filename
  douts "Password file succesfully read!"
  password_server_id = spawn(fn -> password_server(password_map,password_filename) end)
  douts "Password_server successfully started!"
  {:ok,socket} = :gen_tcp.listen(port,
    [:binary,
       packet: :line, active: false,
       reuseaddr: true])
  socketsAndPids = %{}
  keys_and_values = %{}
  statePid = spawn(fn -> state socketsAndPids end) 
  spawn(fn -> sweeper statePid end)
  broadcastPid = spawn(fn -> broadcast(statePid) end)
  key_value_store_pid = spawn(fn -> key_value_store(keys_and_values) end)
  IO.puts "Accepting connections on port #{inspect port}"
  loop_acceptor(socket,password_server_id,statePid,broadcastPid,key_value_store_pid)
end

## a ram only key value store
defp key_value_store(keys_and_values) do
  receive do 
    {:get,caller,key} ->
      send(caller,{:key,keys_and_values[key]})
    {:set,{k,v}} ->
      key_value_store(Map.put(keys_and_values,k,v))
    anything_else -> 
      raise "Improper message passed to key_value_store: #{inspect anything_else}"
  end
  key_value_store(keys_and_values)
end

## Handles the socket and process states
defp state(socketsAndPids) do
  receive do
    {:get,caller} ->
      send(caller,{:state,socketsAndPids})
    {:get_extra,caller,msg,socket} ->
      send caller, {:state_with_msg, socketsAndPids,msg}
    {:insert,{k,v}} ->
      state(Map.put(socketsAndPids,k,v))
    {:remove,socket} ->
      state(Map.delete(socketsAndPids,socket))
    anything_else ->
      raise "improper message passed to state: #{inspect anything_else}"
  end
  state(socketsAndPids)
end

## Sweeps up dead processes from state server
defp sweeper(statePid) do
  send(statePid,{:get,self()})
  receive do
    {:state,socketsAndPids} ->
      Map.keys(socketsAndPids) |>
      Enum.map(fn socket -> if !Process.alive?(socketsAndPids[socket].pid) do
        :gen_tcp.close socket ## should this go here or in state?
        send(statePid,{:remove,socket})
        end end)
    anything_else ->
      raise "Improper message passed to sweeper: #{inspect anything_else}"
  end
  :timer.sleep(1000) ## sleep the sweeper for 1 second, is this too long?, to cut down on cpu cycles
  sweeper(statePid)
end

## Handles broadcasting chat messages to all people connected, could also be modified in the future for sending server wide alerts
defp broadcast(statePid) do
  receive do
    {:broadcast,msg,socket} ->
      douts("got a msg: #{inspect msg} from: #{inspect socket}")
      send(statePid,{:get_extra,self(),msg,socket})
    {:state_with_msg,sockets_and_pids,msg} ->
      douts("oh here is my state in broadcast: #{inspect sockets_and_pids}")
      Map.keys(sockets_and_pids) |> 
      dpass |>
      Enum.map(fn key_socket -> 
        douts("here is my msg and socket: #{inspect msg} : #{inspect key_socket}")
        spawn(fn -> write_line msg, key_socket end) 
	end)
    anything_else ->
      raise "Improper message passed to broadcast: #{inspect anything_else}"
  end
  broadcast(statePid)
end


## Password server handles, user account creation, validation and password checking
defp password_server(password_map,password_filename) do
  receive do
    {:create_username,username,password} ->
      douts "password_server is adding Username: #{inspect username} Password: #{inspect password}\n"
      {:ok,file_handle} = File.open(password_filename,[:append])
      IO.binwrite(file_handle,"#{username}:#{password}\n")
      File.close(file_handle)
      password_server(Map.put(password_map,username,password),password_filename)
    {:check_username,{caller,username}} ->
      douts("password_server checking username: #{inspect username}#")
      send(caller,{:username_is,(password_map[username] != nil)})
    {:check_username_password,{caller,username,password}} ->
      douts("password_server received a :check from: #{inspect caller} username: #{inspect username} password: #{inspect password}")
      douts("looking up password....")
      douts("our password map: #{inspect password_map}")
      looked_up_password = password_map[username]
      douts("the looked up pasword is: #{inspect looked_up_password}")
      return_value = password == password_map[username]
      douts("PASSWORD SERVER IS STILL ALIVE!!!!!")
      douts("Passwords match: #{inspect return_value}")
      send(caller,{:password_is,return_value})
      douts("password_server sent data back to caller!")
    anything_else ->
      douts("password_server received: #{inspect anything_else}")
  end
  password_server(password_map,password_filename)
end

## Main tcp socket loop spawns off clients
defp loop_acceptor(socket,password_server_id,statePid,broadcastPid,key_value_store_pid) do
  {:ok,client_socket} = :gen_tcp.accept(socket) ### could error here!
  spawn(fn -> 
    start_loop(client_socket,password_server_id,statePid,broadcastPid,key_value_store_pid) end)
  loop_acceptor(socket,password_server_id,statePid,broadcastPid,key_value_store_pid)
end

## Begins our client handler and spawns a watchdog timer
defp start_loop(socket,password_server_id,state_pid,broadcast_pid,key_value_store_pid) do
  write_line("Welcome to Elixir Chat\n",socket)
  name = login(socket,password_server_id)
  send(state_pid,{:insert,{socket,%State_Value{pid: self(), name: name}}}) ## {self(),name}}})
  watchdog_pid = spawn_link(fn -> watchdog_timer(socket) end)
  write_line("You will be disconnected after 15 minutes of inactivity!\n",socket)
  loop_server(socket,name,state_pid,broadcast_pid,key_value_store_pid,watchdog_pid)
end

## Watchdog Timer which must be messaged every so often or it dies
defp watchdog_timer(socket) do
##  write_line "Disconnecting in 15 minutes!\n", socket
  receive do
    :reset -> watchdog_timer socket
    anything_else -> 
      raise "watchdog_timer received an incorrect message: #{inspect anything_else}"
    after 5*60*1000  -> write_line "Disconnecting in 10 minutes!\n", socket
  end
  watchdog_timer2 socket 
end

defp watchdog_timer2(socket) do
  receive do
    :reset -> watchdog_timer socket
    anything_else ->
      raise "watchdog_timer2 received and incorrect message: #{inspect anything_else}"
    after 5*60*1000 -> write_line "Disconnecting in 5 minutes\n", socket
  end
  watchdog_timer3 socket
end

defp watchdog_timer3(socket) do
  receive do
    :reset -> watchdog_timer socket
    anything_else ->
      raise "watchdog_timer3 received and incorrect message: #{inspect anything_else}"
    after 5*60*1000 -> write_line "Disconnected Due to 15 minutes of Inactivity!!!\n", socket 
  end
  :gen_tcp.close socket
  Process.exit self(), {:kill,"#{inspect socket} is going to be disconnected because of inactivity within 1 second!"}
end

## Login function is kinda big and a bit messy, should break it up
defp login(socket,password_server_id) do
  write_line("Enter your User name: ",socket)
  username = String.rstrip(read_line(socket))
  case check_username(username) do
    true ->
      case check_username_exists(username,password_server_id) do
        true ->
          write_line("Password: ",socket)
          password = String.rstrip(read_line(socket))
          douts("Sending username: #{inspect username} and password: #{inspect password}   to password server...\n")
          send(password_server_id,{:check_username_password,{self(),username,password}})
          douts("password sent to password server... Now waiting for a response\n")
          receive do
            {:password_is,true} -> 
              write_line("::WELCOME #{username}::\n",socket)
              username
            {:password_is,false} ->
              write_line("Invalid Password!\nDisconnected......\n",socket)
              File.close(socket)
              Process.exit(self(),{:kill,"Invalid Password"})
            anything_else ->
              raise "Improper messaged passed to login: #{inspect anything_else}"
          end
        false ->
          ## write_line("Need to add functionality for adding new users\n",socket)
          write_line("Did I get that right #{inspect username}(y/n) ? ",socket)
          yes_or_no = String.rstrip(read_line(socket))
          case (yes_or_no == "y") or (yes_or_no == "Y") do
            true -> 
              write_line("Password: ",socket)
              password_first = String.rstrip(read_line(socket))
              write_line("Enter Password Again: ",socket)
              password_second = String.rstrip(read_line(socket))
              case password_first == password_second do
                true ->
                  write_line("Passwords Match! Creating Account #{inspect username}\n",socket)
                  send(password_server_id,{:create_username,username,password_first})
                  username
                false -> 
                  write_line("Passwords DO NOT MATCH!\n",socket)
                  login(socket,password_server_id)
              end
            false ->
              write_line("Ok...\nEnter the name you want to login as\n",socket)
              login(socket,password_server_id)
          end
      end
    false ->
      write_line("Invalid Username!\n",socket)
      login(socket,password_server_id)
  end
end

defp check_username(name) do
  Regex.match?(~r/^[a-zA-Z]+$/,name)
end

defp check_username_exists(username,password_server_id) do
  send(password_server_id,{:check_username,{self(),username}})
  receive do
    {:username_is,true} -> true
    {:username_is,false} -> false
    anything_else ->
      raise "Improper message passed to check_user_name_exists: #{inspect anything_else}"
  end
end

def read_passwords_file(file_name) do
  file_contents_by_lines = String.split((String.rstrip(File.read!(file_name))),"\n")
  douts("Passwords file contents: #{inspect file_contents_by_lines}")
  password_map = contents_of_lines_to_map(file_contents_by_lines,%{})
  douts "Our Passowrd Map is: #{inspect password_map}"
  password_map
end

defp contents_of_lines_to_map([],map) do map end

defp contents_of_lines_to_map([line|more_lines],map) do
   douts("ok our current line being parsed is: #{inspect line}")
   {k,v} = password_line_parse line
   douts("ok our key value pair is: #{inspect {k,v}}")
   contents_of_lines_to_map(more_lines,Map.put(map,k,v))
end

def password_line_parse(line) do
  [k,v] = String.split(line,":")
  {k,v}
end

## get_name_color looks up a name and a returns a valid color for it
defp get_name_color(name) do
  douts "looking up #{inspect name} in Color Databse\n"
  name_and_color = Amnesia.transaction do
    Color.read name
  end
  douts "The lookup has returned #{inspect name_and_color}\n"
  case name_and_color do
    :badarg -> 'w'
    :nil -> 'w'
    valid_lookup -> valid_lookup.color
  end
end

## The Main Client loops, handles reading and dispatching things users type in
defp loop_server(socket,name,state_pid,broadcastPid,key_value_store_pid,watchdog_pid) do
  line = String.to_char_list(read_line socket)
  send watchdog_pid, :reset
  case line do
    [?c,?h,?a,?t,?\ |chat_message] ->
      mods = get_name_color name
      colorful_name_with_colon = sigil_S(<<"#{name}:">>, mods)
      send(broadcastPid, {:broadcast,"#{colorful_name_with_colon} #{chat_message}", socket})
    [?g,?e,?t,?\ |key_with_white_space] ->
      key = String.rstrip(String.lstrip(to_string(key_with_white_space)))
      send(key_value_store_pid,{:get,self(),key})
      receive do
        {:key,value} -> 
          write_line("#{inspect value}\n",socket)
       end
    [?s,?e,?t,?\ |key_and_value] ->
      key_and_value_split = String.split(to_string(key_and_value))
      case length(key_and_value_split) == 2 do
        true -> 
          [key,value] = key_and_value_split
          send(key_value_store_pid,{:set,{key,value}})
        false -> write_line("Invalid Key Value Pair\n",socket)
      end
    [?e,?v,?a,?l,?\ |code_string] -> ## THIS IS EXTREMELY DANGEROUS AND INSECURE!!!!! :D
      value = Code.eval_string code_string, [] ## DANGER
      write_line("#{inspect value}\n",socket)     ## DANGER
    [?b,?a,?d | junk] -> 
      badguy = Amnesia.transaction do
        Item.read("Badguy")
      end
      write_line("The current badguy is: #{inspect badguy.value}\n",socket)
    [?p,?s,?e,?t,?\ |key_and_value] ->
      key_and_value_split = String.split(to_string(key_and_value))
      case length(key_and_value_split) == 2 do
        true ->
          [key,value] = key_and_value_split
          Amnesia.transaction do
            %Item{key: key, value: value} |> Item.write
          end
        false -> write_line("Invalid Key Value Pair\n", socket)
      end
    [?p,?g,?e,?t,?\ |key_with_white_space] ->
      key = String.rstrip(String.lstrip(to_string(key_with_white_space)))
      key_and_value = Amnesia.transaction do
        Item.read key
      end
      case key_and_value != nil do
        true -> write_line("#{inspect key_and_value.value}\n",socket)
        false -> write_line("Key #{inspect key} does not exist!\n",socket)
      end
    [?c,?o,?l,?o,?r,?\ |color_to_lookup_with_white_space] ->
       color_to_lookup = String.rstrip(String.lstrip(to_string(color_to_lookup_with_white_space)))
       color_mod = %{"white" => 'w', "red" => 'r', "green" => 'g', "blue" => 'b', "cyan" => 'c', "magenta" => 'm', "yellow" => 'y'}[color_to_lookup]
       case color_mod != nil do
         true -> 
           Amnesia.transaction do
             %Color{name: name, color: color_mod} |> Color.write
           end
         false ->
           write_line "#{inspect color_to_lookup} is an invalid color!\n", socket
       end
    [?w,?h,?o | junk] -> 
      write_line("These people are currently logged in:\n", socket)
      send state_pid, {:get,self()}
      receive do
        {:state,sockets_and_pids} -> 
          douts "who command in function loop_server has received sockets_and_pids: #{inspect sockets_and_pids}"
          Map.keys(sockets_and_pids) |>
          dpass |>
          Enum.map(fn key ->
            douts "Name we are trying to write out is: #{inspect sockets_and_pids[key].name}\n"
            write_line("  #{sockets_and_pids[key].name}\n", socket)
          end)
        anything_else ->
          raise "loop_server received an invalid message in who: #{inspect anything_else}"
      end
    [?p,?i,?n,?g | junk] -> write_line("PONG!\n",socket)
    [?d,?i,?n,?g | junk] -> write_line("DING!\a\n",socket)
    _ -> write_line("I do not understand: #{line}",socket)
  end
  loop_server(socket,name,state_pid,broadcastPid,key_value_store_pid,watchdog_pid)
end

## Reads a line from a socket
defp read_line(socket) do
  {:ok, data} = :gen_tcp.recv(socket,0)
  douts "Read in data: #{inspect data} : from #{inspect socket}"
  data
end

## Writes a line to a socket
defp write_line(line,socket) do
  douts("trying to write: #{line} to #{inspect socket}")
  :gen_tcp.send(socket,line)
end

## Main function for the MudServer Application!
def main(args) do
  Elmud.start 4000
end

end

## port = 4000

## spawn(fn -> Elmud.start port end) ## uncomment this to make it autoboot
