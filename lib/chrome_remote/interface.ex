defmodule ChromeRemote.Interface do
  protocol_path = Path.join(:code.priv_dir(:chrome_remote), "protocol.json")
  protocol = File.read!(protocol_path) |> Jason.decode!()

  Enum.each(protocol["domains"], fn domain ->
    defmodule Module.concat(ChromeRemote.Interface, domain["domain"]) do
      @moduledoc domain["description"]

      @spec experimental?() :: true | false
      def experimental?(), do: unquote(domain["experimental"] == true)

      for command <- domain["commands"] do
        name = command["name"]
        description = command["description"]

        doc_parameters =
          command["parameters"]
          |> List.wrap()
          |> Enum.map(fn param ->
            description =
              param["description"]
              |> to_string
              |> String.replace("\n", "")

            "    #{param["name"]} <#{param["$ref"] || param["type"]}> - #{description}"
          end)
          |> Enum.join("\n")

        spec_params =
          command["parameters"]
          |> List.wrap()
          |> Enum.map(fn param ->
            if param["optional"] != true do
              name = param["name"]

              type =
                case param["type"] do
                  "object" -> "map()"
                  "boolean" -> "boolean()"
                  "any" -> "any()"
                  "array" -> "list()"
                  "integer" -> "integer()"
                  "number" -> "number()"
                  _ -> "String.t()"
                end

              "#{name}: #{type}"
            else
              nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        parameters_required = not Enum.empty?(spec_params)

        spec_params =
          "%{#{Enum.join(spec_params, ", ")}}"
          |> Code.string_to_quoted!()

        @doc """
          #{description}

          ## Parameters:\n#{doc_parameters}
        """
        if parameters_required do
          @spec unquote(:"#{name}")(pid(), unquote(spec_params), keyword()) :: any()
          def unquote(:"#{name}")(page_pid, parameters, opts \\ []) do
            ChromeRemote.Page.execute_command(
              page_pid,
              unquote("#{domain["domain"]}.#{name}"),
              parameters,
              opts
            )
          end

          @spec unquote(:"#{name}!")(pid(), unquote(spec_params), keyword()) :: any()
          def unquote(:"#{name}!")(page_pid, parameters, opts \\ []) do
            {:ok, value} = unquote(:"#{name}")(page_pid, parameters, opts)
            value
          end
        else
          @spec unquote(:"#{name}")(pid(), unquote(spec_params), keyword()) :: any()
          def unquote(:"#{name}")(page_pid, parameters \\ %{}, opts \\ []) do
            ChromeRemote.Page.execute_command(
              page_pid,
              unquote("#{domain["domain"]}.#{name}"),
              parameters,
              opts
            )
          end

          @spec unquote(:"#{name}!")(pid(), unquote(spec_params), keyword()) :: any()
          def unquote(:"#{name}!")(page_pid, parameters \\ %{}, opts \\ []) do
            {:ok, value} = unquote(:"#{name}")(page_pid, parameters, opts)
            value
          end
        end
      end
    end
  end)
end
