defmodule ChromeRemote.Page.Authentication do
  use GenServer
  alias __MODULE__
  alias ChromeRemote.Page
  alias ChromeRemote.Interface.Network

  defstruct page: nil,
            credentials: nil,
            attempted_auth: []

  def start_link(args \\ [], opts \\ []), do: GenServer.start_link(__MODULE__, args, opts)

  @impl true
  def init(page: page, credentials: credentials) do
    send(self(), :setup)
    {:ok, %Authentication{page: page, credentials: credentials}}
  end

  @impl true
  def handle_info(:setup, %{page: page} = state) do
    {:ok, _} = Network.setRequestInterception(page, %{patterns: [%{urlPattern: "*"}]})
    :ok = Page.subscribe(page, "Network.requestIntercepted")
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:chrome, "Network.requestIntercepted",
         %{"params" => %{"interceptionId" => interception_id, "authChallenge" => _}}},
        %{
          page: page,
          credentials: %{username: username, password: password},
          attempted_auth: attempted_auth
        } = state
      ) do
    {response, attempted_auth} =
      attempted_auth
      |> Enum.find(&(&1 == interception_id))
      |> case do
        nil ->
          {"ProvideCredentials", [interception_id | attempted_auth]}

        id ->
          {"CancelAuth", List.delete(attempted_auth, id)}
      end

    Network.continueInterceptedRequest(page, %{
      interceptionId: interception_id,
      authChallengeResponse: %{
        response: response,
        username: username,
        password: password
      }
    })

    {:noreply, %Authentication{state | attempted_auth: attempted_auth}}
  end

  @impl true
  def handle_info(
        {:chrome, "Network.requestIntercepted",
         %{"params" => %{"interceptionId" => interception_id}}},
        %{page: page} = state
      ) do
    Network.continueInterceptedRequest(page, %{interceptionId: interception_id})
    {:noreply, state}
  end
end
