defmodule ChromeRemote.Chrome do
  use GenServer
  alias __MODULE__
  alias ChromeRemote.Protocol.HTTP

  defstruct credentials: nil,
            port: nil,
            host: nil,
            listeners: []

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

    state =
      %Chrome{credentials: credentials}
      |> launch(opts)

    {:ok, state}
  end

  # -----

  def list_pages(pid), do: get_http_uri(pid) |> HTTP.call("/json/list")
  def activate_page(pid, page_id), do: get_http_uri(pid) |> HTTP.call("/json/activate/#{page_id}")
  def version(pid), do: get_http_uri(pid) |> HTTP.call("/json/version")

  def new_page(pid, opts \\ []) do
    data = get_http_uri(pid) |> HTTP.call!("/json/new")
    credentials = get_credentials(pid)

    {:ok, page} =
      opts
      |> Keyword.merge(chrome_pid: pid, page_id: data["id"], credentials: credentials)
      |> ChromeRemote.Page.start_link()

    {:ok, page}
  end

  def close_page(pid, page) do
    page_id = ChromeRemote.Page.get_page_id(page)
    get_http_uri(pid) |> HTTP.call("/json/close/#{page_id}")
    Process.exit(page, :shutdown)
    :ok
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
  def handle_info({_, {:data, _message}}, state), do: {:noreply, state}

  @impl true
  def handle_call(:get_credentials, _from, %{credentials: credentials} = state) do
    {:reply, credentials, state}
  end

  @impl true
  def handle_call(:get_http_uri, _, state) do
    {:reply, http_uri(state), state}
  end

  defp http_uri(%{host: host, port: port}), do: URI.parse("http://#{host}:#{port}")

  # -----

  defp launch(state, opts) do
    executable =
      System.get_env("CHROME_EXECUTABLE") ||
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    wrapper = Path.join(:code.priv_dir(:chrome_remote), "wrapper.sh")

    command = "#{wrapper} '#{executable}' #{render_opts(opts)}"
    Port.open({:spawn, command}, [:stderr_to_stdout])

    receive do
      {_, {:data, _}} -> nil
    end

    uri =
      receive do
        {_, {:data, message}} ->
          "DevTools listening on " <> address =
            message
            |> to_string()
            |> String.trim()

          URI.parse(address)
      end

    %{state | port: uri.port, host: uri.host}
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
