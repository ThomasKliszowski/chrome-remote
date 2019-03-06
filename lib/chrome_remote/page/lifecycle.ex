defmodule ChromeRemote.Page.Lifecycle do
  use GenServer
  alias __MODULE__
  alias ChromeRemote.Page
  alias ChromeRemote.Interface

  defstruct page: nil,
            loaded: false,
            listeners: []

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
    :ok = Page.subscribe(page, "Page.loadEventFired")
    {:noreply, state}
  end

  @impl true
  def handle_info(:navigating, state) do
    {:noreply, %{state | loaded: false}}
  end

  @impl true
  def handle_info({:chrome, "Page.loadEventFired", _}, %{listeners: listeners} = state) do
    listeners |> Enum.each(&GenServer.reply(&1, :ok))
    {:noreply, %{state | loaded: true, listeners: []}}
  end

  @impl true
  def handle_call(:wait_for_loading, _, %{loaded: true} = state), do: {:reply, :ok, state}

  @impl true
  def handle_call(:wait_for_loading, from, %{listeners: listeners} = state) do
    listeners = [from | listeners]
    {:noreply, %{state | listeners: listeners}}
  end
end
