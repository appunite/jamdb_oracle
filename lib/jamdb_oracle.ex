defmodule Jamdb.Oracle do
  @vsn "0.4.2"
  @moduledoc """
  Adapter module for Oracle. `DBConnection` behaviour implementation.

  It uses `jamdb_oracle` for communicating to the database.

  """

  use DBConnection

  defstruct [:pid, :mode, :cursors]  

  @doc """
  Starts and links to a database connection process.

  See [`Ecto.Adapters.Jamdb.Oracle`](Ecto.Adapters.Jamdb.Oracle.html#module-connection-options).

  By default the `DBConnection` starts a pool with a single connection.
  The size of the pool can be increased with `:pool_size`. The ping interval 
  to validate an idle connection can be given with the `:idle_interval` option.
  """
  @spec start_link(opts :: Keyword.t) :: 
    {:ok, pid()} | {:error, any()}
  def start_link(opts) do
    DBConnection.start_link(Jamdb.Oracle, opts)
  end

  @doc """
  Runs the SQL statement.

  See `DBConnection.prepare_execute/4`.

  In case of success, it must return an `:ok` tuple containing
  a map with at least two keys:

    * `:num_rows` - the number of rows affected
    * `:rows` - the result set as a list  
  """
  @spec query(conn :: any(), sql :: any(), params :: any()) ::
    {:ok, any()} | {:error | :disconnect, any()}
  def query(conn, sql, params \\ [])
  def query(pid, sql, params) when is_pid(pid), do: query(%{pid: pid}, sql, params)
  def query(%{pid: pid}, sql, params) do
    case :jamdb_oracle.sql_query(pid, stmt(sql, params)) do
      {:ok, [{:result_set, columns, _, rows}]} ->
        {:ok, %{num_rows: length(rows), rows: rows, columns: columns}}
      {:ok, [{:fetched_rows, _, _, _} = result]} -> {:cont, result}
      {:ok, [{:proc_result, 0, rows}]} -> {:ok, %{num_rows: length(rows), rows: rows}}
      {:ok, [{:proc_result, _, msg}]} -> {:error, msg}
      {:ok, [{:affected_rows, num_rows}]} -> {:ok, %{num_rows: num_rows, rows: nil}}
      {:ok, result} -> {:ok, result}
      {:error, :local, _} -> {:error, "Data is incomplete. Pass :read_timeout as connection parameter."}
      {:error, _, err} -> {:disconnect, err}
    end
  end

  defp stmt({:fetch, sql, params}, _), do: {:fetch, sql, params}
  defp stmt({:fetch, cursor, row_format, last_row}, _), do: {:fetch, cursor, row_format, last_row}
  defp stmt({:batch, sql, params}, _), do: {:batch, sql, params}
  defp stmt(sql, params), do: {sql, params}

  @impl true
  def connect(opts) do
    database = Keyword.fetch!(opts, :database) |> to_charlist
    env = if( hd(database) == ?:, do: [sid: tl(database)], else: [service_name: database] )
    |> Keyword.put_new(:host, Keyword.fetch!(opts, :hostname) |> to_charlist)
    |> Keyword.put_new(:port, Keyword.fetch!(opts, :port))
    |> Keyword.put_new(:user, Keyword.fetch!(opts, :username) |> to_charlist)
    |> Keyword.put_new(:password, Keyword.fetch!(opts, :password) |> to_charlist)
    |> Keyword.put_new(:timeout, Keyword.fetch!(opts, :timeout))
    params = if( Keyword.has_key?(opts, :parameters) == true,
      do: opts[:parameters], else: [] )
    sock_opts = if( Keyword.has_key?(opts, :socket_options) == true,
      do: [socket_options: opts[:socket_options]], else: [] )
    case :jamdb_oracle.start_link(sock_opts ++ params ++ env) do
      {:ok, pid} -> {:ok, %Jamdb.Oracle{pid: pid, mode: :idle}}
      {:error, [{:proc_result, _, msg}]} -> {:error, error!(msg)}
      {:error, err} -> {:error, error!(err)}
    end
  end

  @impl true
  def disconnect(_err, %{pid: pid}) do
    :jamdb_oracle.stop(pid) 
  end

  @impl true
        def handle_execute(%Jamdb.Oracle.Query{batch: true, query_rows_count: query_rows_count, statement: statement} = query, params, _opts, s) do
    with {:ok, result} <- query(s, {:batch, to_charlist(statement), Enum.chunk_every(params, query_rows_count)}, []),
         {:ok, _} <- auto_commit(s) do
      {:ok, query, result, s}
    else
      {:error, err} -> {:error, error!(err, statement, params), s}
      {:disconnect, err} -> {:disconnect, error!(err, statement, params), s}
    end
  end

  def handle_execute(%Jamdb.Oracle.Query{statement: statement} = query, params, opts, s) do
    with returning <- Enum.map(Keyword.get(opts, :out, []), fn elem -> {:out, elem} end),
      {:ok, result} <- query(s, to_charlist(statement), Enum.concat(params, returning)),
      {:ok, result} <- recv_execute(result, query),
      {:ok, _} <- auto_commit(s) do
        {:ok, query, result, s}
    else
      {:error, err} -> {:error, error!(err, statement, params), s}
      {:disconnect, err} -> {:disconnect, error!(err, statement, params), s}
    end
  end

  defp auto_commit(%{mode: :idle} = s), do: query(s, 'COMMIT')
  defp auto_commit(_s), do: {:ok, []}

  defp recv_execute(result, %Jamdb.Oracle.Query{result_types: nil}), do: {:ok, result}
  defp recv_execute(result, %Jamdb.Oracle.Query{result_types: []}), do: {:ok, result}
  defp recv_execute(result, %Jamdb.Oracle.Query{result_types: [type | _]}) do
    # For now we support the first type of result types
    {:ok, %{result | rows: type.decode(result.rows)}}
  end

  @impl true
  def handle_prepare(%Jamdb.Oracle.Query{statement: statement}=query, opts, s) when is_binary(statement) do
    result_types = recv_describe(statement, opts, s)
    query = %Jamdb.Oracle.Query{query | result_types: result_types}

    {:ok, query, s}
  end
  def handle_prepare(query, _opts, s), do: {:ok, query, s}

  defp recv_describe(_statement, opts, _s) do
    case Keyword.get(opts, :maybe) do
      :decimal -> [Jamdb.Oracle.Extensions.Numeric]
      _ -> []
    end
  end

  @impl true
  def handle_begin(opts, %{mode: mode} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when mode == :idle ->
        statement = "SAVEPOINT tran"
        handle_transaction(statement, opts, %{s | mode: :transaction})
      :savepoint when mode == :transaction ->
        statement = "SAVEPOINT " <> Keyword.get(opts, :name, "svpt")
        handle_transaction(statement, opts, %{s | mode: :transaction})
      status when status in [:transaction, :savepoint] ->
        {status, s}
    end
  end

  @impl true
  def handle_commit(opts, %{mode: mode} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when mode == :transaction ->
        statement = "COMMIT"
        handle_transaction(statement, opts, %{s | mode: :idle})
      :savepoint when mode == :transaction ->
        {:ok, [], %{s | mode: :transaction}}
      status when status in [:transaction, :savepoint] ->
        {status, s}
    end
  end

  @impl true
  def handle_rollback(opts, %{mode: mode} = s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction when mode in [:transaction, :error] ->
        statement = "ROLLBACK TO tran"
        handle_transaction(statement, opts, %{s | mode: :idle})
      :savepoint when mode in [:transaction, :error] ->
        statement = "ROLLBACK TO " <> Keyword.get(opts, :name, "svpt")
        handle_transaction(statement, opts, %{s | mode: :transaction})
      status when status in [:transaction, :savepoint] ->
        {status, s}
    end
  end

  defp handle_transaction(statement, _opts, s) do
    case query(s, statement |> to_charlist) do
      {:ok, result} -> {:ok, result, s}
      {:error, err} -> {:error, error!(err, statement), s}
      {:disconnect, err} -> {:disconnect, error!(err, statement), s}
    end
  end

  @impl true
  def handle_declare(query, params, _opts, s) do
    {:ok, query, %{params: params}, s}
  end

  @impl true
  def handle_fetch(query, %{params: params}, _opts, %{cursors: nil} = s) do
    %Jamdb.Oracle.Query{statement: statement} = query
    case query(s, {:fetch, statement |> to_charlist, params}) do
      {:cont, {_, cursor, row_format, rows}} ->
        cursors = %{cursor: cursor, row_format: row_format, last_row: List.last(rows)}
        {:cont,  %{num_rows: length(rows), rows: rows}, %{s | cursors: cursors}}
      {:ok, result} -> 
        {:halt, result, s}
      {:error, err} -> {:error, error!(err, statement, params), s}
      {:disconnect, err} -> {:disconnect, error!(err, statement, params), s}
    end
  end
  def handle_fetch(_query, _cursor, _opts, %{cursors: cursors} = s) do
    %{cursor: cursor, row_format: row_format, last_row: last_row} = cursors
    case query(s, {:fetch, cursor, row_format, last_row}) do
      {:cont, {_, _, _, rows}} ->
        rows = tl(rows)
        {:cont,  %{num_rows: length(rows), rows: rows}, 
        %{s | cursors: %{cursors | last_row: List.last(rows)}}}
      {:ok, %{rows: rows} = result} -> 
        rows = tl(rows)
        {:halt, %{result | num_rows: length(rows), rows: rows}, s}
      {:error, err} -> {:error, error!(err), s}
      {:disconnect, err} -> {:disconnect, error!(err), s}
    end
  end

  @impl true
  def handle_deallocate(_query, _cursor, _opts, s) do
    {:ok, nil, %{s | cursors: nil}}
  end

  @impl true
  def handle_close(_query, _opts, s) do
    {:ok, nil, s}
  end

  @impl true
  def handle_status(_opts, %{mode: mode} = s) do
    {mode, s}
  end

  @impl true
  def checkin(s) do
    {:ok, s}
  end

  @impl true
  def checkout(s) do
    case query(s, 'SESSION') do
      {:ok, _} -> {:ok, s}
      {:error, err} ->  {:disconnect, error!(err, 'SESSION'), s}
    end
  end

  @impl true
  def ping(%{mode: :idle} = s) do
    case query(s, 'PING') do
      {:ok, _} -> {:ok, s}
      {:error, err} -> {:disconnect, error!(err, 'PING'), s}
      {:disconnect, err} -> {:disconnect, error!(err, 'PING'), s}
    end
  end
  def ping(%{mode: :transaction} = s) do
    {:ok, s}
  end

  defp error!(msg, query \\ nil, params \\ [])
  defp error!(msg, query, params) when is_binary(msg),
    do: Jamdb.Oracle.Error.exception(message: msg, query: query, params: params)
  defp error!(msg, query, params), do: msg |> inspect |> error!(query, params)

  @doc """
  Returns the configured JSON library.

  To customize the JSON library, include the following in your `config/config.exs`:

      config :jamdb_oracle, :json_library, SomeJSONModule

  Defaults to [`Jason`](https://hexdocs.pm/jason)
  """
  @spec json_library() :: module()
  def json_library() do
    Application.get_env(:jamdb_oracle, :json_library, Jason)
  end

end

defimpl DBConnection.Query, for: Jamdb.Oracle.Query do
  @time_marker {1000, 01, 01}

  def parse(query, _), do: query
  def describe(query, _), do: query

  def decode(_, %{rows: []} = result, _), do: result
  def decode(_, %{rows: rows} = result, opts) when rows != nil, 
    do: %{result | rows: Enum.map(rows, fn row -> decode(row, opts[:decode_mapper]) end)}
  def decode(_, result, _), do: result

  defp decode(row, nil), do: Enum.map(row, fn elem -> decode(elem) end)
  defp decode(row, mapper), do: mapper.(decode(row, nil))

  defp decode(:null), do: nil
  defp decode({elem}) when is_float(elem) do
    if elem == round(elem) do # because Decimal.new(1) != Decimal.new(1.0)
      Decimal.cast(round(elem))
    else
      Decimal.cast(elem)
    end
  end
  defp decode({elem}) when is_number(elem), do: elem
  defp decode({@time_marker, time}), do: to_time(time)
  defp decode({date, time}) when is_tuple(date), do: to_naive({date, time})
  defp decode({date, time, tz}) when is_tuple(date) and is_list(tz), do: to_date({date, time, tz})
  defp decode({date, time, _}) when is_tuple(date), do: to_utc({date, time})
  defp decode(elem) when is_list(elem), do: to_binary(elem)
  defp decode(elem), do: elem

  def encode(_, [], _), do: []
  def encode(_, params, opts) do
    types = Enum.map(Keyword.get(opts, :in, []), fn elem -> elem end)
    Enum.map(encode(params, types), fn elem -> encode(elem) end)
  end

  defp encode(params, []), do: params
  defp encode([%Ecto.Query.Tagged{type: :binary} = elem | next1], [_type | next2]),
    do: [ elem | encode(next1, next2)]
  defp encode([elem | next1], [type | next2]) when type in [:binary, :binary_id, Ecto.UUID],
    do: [ %Ecto.Query.Tagged{value: elem, type: :binary} | encode(next1, next2)]
  defp encode([elem | next1], [_type | next2]), do: [ elem | encode(next1, next2)]

  defp encode(nil), do: :null
  defp encode(true), do: 1
  defp encode(false), do: 0
  defp encode(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp encode(%DateTime{} = datetime), do: encode(DateTime.to_naive(datetime))
  defp encode(%Time{} = time), do: {@time_marker, Time.to_erl(time)}
  defp encode(%NaiveDateTime{microsecond: {microsecond, 6}} = naive) do
    {{year, month, day}, {hour, minute, second}} = NaiveDateTime.to_erl(naive)
    {{year, month, day}, {hour, minute, second, microsecond}}
  end
  defp encode(%NaiveDateTime{microsecond: {microsecond, p}} = naive) when p > 6 do
    microsecond = round(microsecond / round(:math.pow(10, p)) * round(:math.pow(10, 6)))
    {{year, month, day}, {hour, minute, second}} = NaiveDateTime.to_erl(naive)
    {{year, month, day}, {hour, minute, second, microsecond}}
  end
  defp encode(%NaiveDateTime{microsecond: {microsecond, p}} = naive) when p > 0 do
    microsecond = microsecond * round(:math.pow(10, 6 - p))
    {{year, month, day}, {hour, minute, second}} = NaiveDateTime.to_erl(naive)
    {{year, month, day}, {hour, minute, second, microsecond}}
  end
  defp encode(%NaiveDateTime{} = naive) do
    NaiveDateTime.to_erl(naive)
  end
  defp encode(%Ecto.Query.Tagged{value: elem}), do: elem
  defp encode(elem) when is_binary(elem) do
    if String.valid?(elem) do
      elem |> to_charlist
    else
      elem |> Base.encode16() |> to_charlist
    end
  end
  defp encode(%Postgrex.INET{address: address, netmask: netmask}),
    do: Enum.join(address |> Tuple.to_list, ".") <> "/#{netmask || 32}" |> to_charlist
  defp encode(elem) when is_map(elem) or is_list(elem),
       do: Jamdb.Oracle.json_library().encode!(elem) |> to_charlist()
  defp encode(elem), do: elem

  defp expr(list) when is_list(list) do
    Enum.map(list, fn 
      :null -> nil
      elem  -> elem
    end)
  end

  defp to_binary(list) when is_list(list) do
    try do
      :binary.list_to_bin(list)
    rescue
      ArgumentError ->
        Enum.map(expr(list), fn
          elem when is_list(elem) -> expr(elem)
          other -> other
        end) |> Enum.join
    end
  end
  defp to_naive({date, {hour, min, sec, ms}}) when is_integer(sec) and is_integer(ms),
       do: NaiveDateTime.from_erl!({date, {hour, min, sec}}, {round(ms / 1000), 6})

  defp to_naive({date, {hour, min, sec}}) when is_integer(sec),
    do: NaiveDateTime.from_erl!({date, {hour, min, sec}})

  defp to_naive({date, {hour, min, sec}}),
       do: NaiveDateTime.from_erl!({date, {hour, min, trunc(sec)}}, parse_sec(sec))

  defp to_utc({date, time}),
    do: DateTime.from_naive!(to_naive({date, time}), "Etc/UTC")

  defp to_date({{year, month, day}, {hour, min, sec}, tz}),
    do: %DateTime{year: year, month: month, day: day, hour: hour, minute: min,
	second: trunc(sec), microsecond: parse_sec(sec), time_zone: to_binary(tz),
	zone_abbr: "UTC", utc_offset: 0, std_offset: 0}

  defp to_time(time), do: Time.from_erl!(time)

  defp parse_sec(sec),
    do: {trunc((sec - trunc(sec)) * 1000000) , 6}

end
