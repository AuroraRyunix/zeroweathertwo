defmodule ZeroWeather.Cache do
  @moduledoc """
  Simple in-memory ETS cache with TTL for weather and radar responses.
  """
  use GenServer

  @table :zero_weather_cache

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Retrieves a value from the cache. Returns `{:ok, value}` or `:error`.
  """
  def get(key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        {:ok, value}

      _ ->
        :error
    end
  end

  @doc """
  Puts a value into the cache with a TTL in seconds.
  """
  def put(key, value, ttl_seconds \\ 300) do
    expires_at = System.system_time(:second) + ttl_seconds
    :ets.insert(@table, {key, value, expires_at})
    :ok
  end

  @doc """
  Fetches an item or executes the fallback function and caches the result.
  """
  def fetch(key, ttl_seconds, fun) when is_function(fun, 0) do
    case get(key) do
      {:ok, val} ->
        {:ok, val}

      :error ->
        case fun.() do
          {:ok, val} ->
            put(key, val, ttl_seconds)
            {:ok, val}

          error ->
            error
        end
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    # Schedule periodic cleanup every 5 minutes
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    # Delete expired records: match spec where expires_at <= now
    match_spec = [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 300_000)
  end
end
