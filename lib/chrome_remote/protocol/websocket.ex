defmodule ChromeRemote.Protocol.WebSocket do
  require Logger
  use WebSockex

  def start_link(url), do: WebSockex.start_link(url, __MODULE__, self())

  def handle_frame({:text, frame_data}, state) do
    send(state, {:message, frame_data})
    {:ok, state}
  end

  def send_frame(socket, frame), do: WebSockex.send_frame(socket, frame)
end
