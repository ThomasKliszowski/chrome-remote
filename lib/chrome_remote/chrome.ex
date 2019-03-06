defmodule ChromeRemote.Chrome do
  use GenServer
  alias ChromeRemote.Protocol.HTTP

  def start_link(args \\ [], opts \\ []), do: GenServer.start_link(__MODULE__, args, opts)

  @impl true
  def init(opts) do
    opts =
      [
        headless: true,
        remote_debugging_port: 0
      ]
      |> Keyword.merge(opts)

    {credentials, opts} = Keyword.pop(opts, :credentials)

    launch(opts)

    state = %{
      host: nil,
      port: nil,
      credentials: credentials,
      listeners: %{
        get_http_uri: []
      }
    }

    {:ok, state}
  end

  # -----

  def list_pages(pid), do: get_http_uri(pid) |> HTTP.call("/json/list")
  def activate_page(pid, page_id), do: get_http_uri(pid) |> HTTP.call("/json/activate/#{page_id}")
  def close_page(pid, page_id), do: get_http_uri(pid) |> HTTP.call("/json/close/#{page_id}")
  def version(pid), do: get_http_uri(pid) |> HTTP.call("/json/version")

  def new_page(pid, opts \\ []) do
    data = get_http_uri(pid) |> HTTP.call!("/json/new")
    credentials = get_credentials(pid)

    opts
    |> Keyword.merge(chrome_pid: pid, page_id: data["id"], credentials: credentials)
    |> ChromeRemote.Page.start_link(opts)
  end

  def get_websocket_uri(pid, page_id) do
    port = get_http_uri(pid) |> Map.get(:port)
    {:ok, pages} = list_pages(pid)

    pages
    |> Enum.find(&(&1["id"] == page_id))
    |> Map.get("webSocketDebuggerUrl")
    |> URI.parse()
    |> Map.put(:port, port)
  end

  # -----

  defp get_http_uri(pid), do: GenServer.call(pid, :get_http_uri, 10_000)
  defp get_credentials(pid), do: GenServer.call(pid, :get_credentials, 10_000)

  # -----

  @impl true
  def handle_info({proc, {:data, message}}, state) when is_list(message) do
    message =
      message
      |> to_string()
      |> String.trim()

    handle_info({proc, {:data, message}}, state)
  end

  @impl true
  def handle_info(
        {_, {:data, "DevTools listening on " <> address}},
        %{listeners: listeners} = state
      ) do
    uri = URI.parse(address)
    port = uri |> Map.get(:port)
    host = uri |> Map.get(:host)
    state = %{state | port: port, host: host, listeners: %{}}

    listeners.get_http_uri |> Enum.each(&GenServer.reply(&1, http_uri(state)))

    {:noreply, state}
  end

  @impl true
  def handle_info({_, {:data, _message}}, state), do: {:noreply, state}

  @impl true
  def handle_call(:get_credentials, _from, %{credentials: credentials} = state) do
    {:reply, credentials, state}
  end

  @impl true
  def handle_call(:get_http_uri, from, %{port: port, listeners: listeners} = state) do
    case port do
      nil ->
        listeners = %{listeners | get_http_uri: [from | listeners.get_http_uri]}
        {:noreply, %{state | listeners: listeners}}

      _port ->
        {:reply, http_uri(state), state}
    end
  end

  defp http_uri(%{host: host, port: port}), do: URI.parse("http://#{host}:#{port}")

  # -----

  defp launch(opts) do
    executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    wrapper = Path.join(:code.priv_dir(:chrome_remote), "wrapper.sh")

    command = "#{wrapper} '#{executable}' #{render_opts(opts)}"
    Port.open({:spawn, command}, [:stderr_to_stdout])
  end

  defp render_opts(opts) do
    Enum.map(opts, fn
      {key, true} -> "--#{render_opt_key(key)}"
      {_, false} -> nil
      {key, value} -> "--#{render_opt_key(key)}=#{value}"
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp render_opt_key(key) when is_atom(key), do: Atom.to_string(key) |> render_opt_key()
  defp render_opt_key(key), do: String.replace(key, "_", "-")
end
