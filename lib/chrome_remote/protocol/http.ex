defmodule ChromeRemote.Protocol.HTTP do
  def call(uri, path) do
    uri
    |> execute_request(path)
    |> handle_response()
  end

  def call!(uri, path) do
    {:ok, data} = call(uri, path)
    data
  end

  defp execute_request(%URI{} = uri, path) do
    url =
      uri
      |> Map.put(:path, path)
      |> URI.to_string()

    with {:ok, resp} <- HTTPoison.get(url),
         body <- Map.get(resp, :body),
         do: body
  end

  defp handle_response(body) do
    with {:ok, formatted_body} <- format_body(body),
         {:ok, json} <- decode(formatted_body) do
      {:ok, json}
    else
      error -> error
    end
  end

  defp format_body(""), do: format_body("{}")
  defp format_body(body), do: {:ok, body}

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:ok, body}
    end
  end
end
