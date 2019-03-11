defmodule ChromeRemote.Page.Lifecycle do
  use GenServer
  alias __MODULE__
  alias ChromeRemote.Page
  alias ChromeRemote.Interface

  defstruct page: nil,
            loaded: false,
            listeners: [],
            url: nil,
            response: nil

  def start_link(args \\ [], opts \\ []), do: GenServer.start_link(__MODULE__, args, opts)

  @impl true
  def init(page: page) do
    send(self(), :setup)
    {:ok, %Lifecycle{page: page}}
  end

  def wait_for_loading(pid), do: GenServer.call(pid, :wait_for_loading, 30_000)

  @impl true
  def handle_info(:setup, %{page: page} = state) do
    {:ok, _} = Interface.Page.enable(page)
    {:ok, _} = Interface.Network.enable(page)
    :ok = Page.subscribe(page, "Page.loadEventFired")
    :ok = Page.subscribe(page, "Network.responseReceived")
    {:noreply, state}
  end

  @impl true
  def handle_info({:navigate, url}, state) do
    {:noreply, %{state | loaded: false, url: url, response: nil}}
  end

  @impl true
  def handle_info(
        {:chrome, "Network.responseReceived",
         %{"params" => %{"response" => %{"url" => resp_url} = response}}},
        %{url: url} = state
      )
      when url == resp_url do
    {:noreply, %{state | response: response}}
  end

  @impl true
  def handle_info({:chrome, "Network.responseReceived", _}, state), do: {:noreply, state}

  @impl true
  def handle_info(
        {:chrome, "Page.loadEventFired", _},
        %{listeners: listeners, response: response} = state
      ) do
    listeners |> Enum.each(&GenServer.reply(&1, response))
    {:noreply, %{state | loaded: true, listeners: []}}
  end

  @impl true
  def handle_call(:wait_for_loading, _, %{loaded: true, response: response} = state),
    do: {:reply, response, state}

  @impl true
  def handle_call(:wait_for_loading, from, %{listeners: listeners} = state) do
    listeners = [from | listeners]
    {:noreply, %{state | listeners: listeners}}
  end
end
