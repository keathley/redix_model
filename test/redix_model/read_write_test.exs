defmodule RedixModel.ReadWriteTest do
  use PropCheck.StateM
  use PropCheck
  use ExUnit.Case

  require Logger
  @moduletag capture_log: true

  property "Can get and set keys" do
    numtests(300, forall cmds in commands(__MODULE__) do
      trap_exit do
        Application.ensure_all_started(:redix)
        flush_database()

        {history, state, result} = run_commands(__MODULE__, cmds)

        Application.stop(:redix)

        (result == :ok)
        |> when_fail(
            IO.puts """
            History: #{inspect history, pretty: true}
            State: #{inspect state, pretty: true}
            Result: #{inspect result, pretty: true}
            """)
        |> aggregate(command_names cmds)
      end
    end)
  end

  def flush_database do
    {:ok, conn} = Redix.start_link()
    Redix.command(conn, ["FLUSHDB"])
    Redix.stop(conn)
  end

  def start_redis do
    Redix.start_link()
  end

  # This is the state of our model
  defstruct contents: %{}, conn: :empty

  @doc """
  Sets the initial state of the model per test run
  """
  def initial_state, do: %__MODULE__{}


  @doc """
  Statefully generate valid command sequences.
  """
  def command(%{conn: :empty}) do
    # The very first thing we need to do is establish a redis connection so
    # we call the module that we're in to do that work.
    {:call, __MODULE__, :start_redis, []}
  end
  def command(%{conn: conn, contents: contents}) do
    keys = Map.keys(contents)

    oneof([
      {:call, Redix, :command, [conn, ["GET", oneof(keys)]]},
      {:call, Redix, :command, [conn, ["SET", binary(), binary()]]},
      {:call, Redix, :command, [conn, ["SET", oneof(keys), binary()]]},
    ])
  end

  @doc """
  Determines if the call is valid in our current state. This is necessary because
  during shrinking commands will be removed from the generated list. We need to
  ensure that those commands are still valid based on the state that we're in.
  """
  def precondition(%{conn: :empty}, {:call, Redix, _, _}), do: false
  def precondition(_, _), do: true


  @doc """
  Moves to the next state. The value is the result of the call but it may be a
  symbolic reference to the result depending on where we are in the process.
  """
  def next_state(state, _value, {:call, _, :command, [_, ["SET", key, value]]}) do
    put_in(state, [:contents, key], value)
  end

  def next_state(state, _value, {:call, _, :command, [_, ["GET", _]]}) do
    state
  end

  # This is a trick to get around symbolic variables. Really we should match on
  # an error clause here as well. There are other ways to solve this problem
  # but I'm using this method to illustrate some of the pain of dealing with
  # symbolic variables generally.
  def next_state(state, {:ok, conn}, {:call, _, :start_redis, _}) do
    %{state | conn: conn}
  end
  def next_state(state, _, {:call, _, :start_redis, _}) do
    state
  end

  @doc """
  Checks the model state after the call is made. The state here is the state
  BEFORE a call was made. The call is the symbolic call that we executed. The
  result is the real result from the call.
  """
  def postcondition(%{contents: contents}, {:call, Redix, :command, [_, cmd]}, result) do
    case cmd do
      ["GET", key] ->
        Map.fetch(contents, key) == result

      ["SET", _key, _value] ->
        result == {:ok, "OK"}
    end
  end

  def postcondition(_, _, _) do
    true
  end
end
