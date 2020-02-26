defmodule ResxHTTP do
    @moduledoc """
      A producer to handle HTTP URIs.

        ResxHTTP.open("https://example.com/foo.csv")

      Add `ResxHTTP` to your list of resx producers.

        config :resx,
            producers: [ResxHTTP]

      ### Types

      MIME types are inferred from the content-type of the HTTP response.

      ### Access

      By default all HTTP resources can be opened. Optionally access can be
      restricted by configuring the `:access` configuration option for the
      application.

        config :resx_http,
            access: fn
                request = %HTTPoison.Request{ url: "https://example.com/foo.csv" } ->
                    %{ request | options: [{ :follow_redirect, true }|request.options] }
                request = %HTTPoison.Request{ url: "https://example.com" <> _ } -> request
                _ -> nil
            end

      The `:access` field should contain a callback function of type
      `(HTTPoison.Request.t -> HTTPoison.Request.t | nil)` where the current
      request is passed to the callback and either the request that should be made
      is returned (this can be the same request or a new one) or `nil` to disallow.
      Valid function formats are any callback variant, see `Callback` for more
      information.
    """
    use Resx.Producer

    alias Resx.Resource
    alias Resx.Resource.Content
    alias Resx.Resource.Reference
    alias Resx.Resource.Reference.Integrity

    @type timestamp :: :server | :client
    @type options :: [

        method: HTTPoison.Request.method,
        headers: HTTPoison.Request.headers,
        body: HTTPoison.Request.body,
        options: HTTPoison.Request.options,
        timestamp: timestamp
    ]

    defp to_request(%Reference{ repository: { request, headers } }, opts), do: { :ok, { update_request(request, opts), headers } }
    defp to_request(url, opts) when is_binary(url) do
        request = %HTTPoison.Request{
            method: opts[:method],
            url: url,
            headers: opts[:headers] || [],
            body: opts[:body] || "",
            options: opts[:options] || []
        }

        { :ok, { request, %{} } }
    end
    defp to_request(_, _), do: { :error, { :invalid_reference, "not an HTTP reference" } }

    defp update_request(request, [{ key, value }|opts]) when key in [:method, :body], do: %{ request | key => value } |> update_request(opts)
    defp update_request(request, [{ :headers, value }|opts]), do: %{ request | headers: merge_headers(request.headers, value || %{}) } |> update_request(opts)
    defp update_request(request, [{ :options, value }|opts]), do: %{ request | options: merge_options(request.options, value || []) } |> update_request(opts)
    defp update_request(request, []), do: request

    defp merge_headers(old, new), do: Map.merge(Map.new(old), Map.new(new))

    defp merge_options(old, new), do: Keyword.merge(old, new)

    defp access?(request) do
        case Application.get_env(:resx_http, :access) do
            nil -> request
            access -> Callback.call(access, [request])
        end
    end

    defp format_http_error({ :ok, response }, _, _), do: { :error, { :internal, response } }
    defp format_http_error({ :error, error }, _, action), do: { :error, { :internal, "failed to #{action} due to: #{HTTPoison.Error.message(error)}" } }

    defp format_timestamp(timestamp) do
        case HTTPDate.parse(timestamp) do
            { :ok, timestamp } -> timestamp
            _ -> DateTime.utc_now
        end
    end

    defp timestamp(%{ "Last-Modified" => timestamp }, :server), do: format_timestamp(timestamp)
    defp timestamp(%{ "Date" => timestamp }, :server), do: format_timestamp(timestamp)
    defp timestamp(headers, nil), do: timestamp(headers, Application.get_env(:resx_http, :timestamp, :server))
    defp timestamp(_, :client), do: DateTime.utc_now

    defp request(request), do: HTTPoison.request(request)

    @impl Resx.Producer
    def schemes(), do: ["https", "http"]

    @doc """
      Opens an HTTP resource.

      By default a GET request is made, this can be changed by specifying the request
      type using the `:method` option.

      The `:timestamp` option allows for choosing between `:server` or `:client`
      timestamps. By default the server timestamp is used, or whatever application
      timestamp setting was given.

        config :resx_http,
            timestamp: :client
    """
    @impl Resx.Producer
    @spec open(Resx.ref, options) :: { :ok, resource :: Resource.t(Content.t) } | Resx.error(Resx.resource_error | Resx.reference_error)
    def open(reference, opts \\ []) do
        with { :request, repo = { :ok, { request, _ } } } <- { :request, to_request(reference, Keyword.merge([method: :get], opts)) },
             { :access, request = %HTTPoison.Request{} } <- { :access, access?(request) },
             { :content, { :ok, response = %HTTPoison.Response{ status_code: status } }, _ } when status >= 200 and status < 300 <- { :content, request(request), repo } do
                headers = Map.new(response.headers)
                content = %Content{
                    type: headers["Content-Type"] || "application/octet-stream",
                    data: response.body
                }
                resource = %Resource{
                    reference: %Reference{
                        adapter: __MODULE__,
                        repository: { request, headers },
                        integrity: %Integrity{
                            timestamp: timestamp(headers, opts[:timestamp]),
                            checksum: nil
                        }
                    },
                    content: content
                }

                { :ok,  resource }
        else
            { :request, error } -> error
            { :access, nil } -> { :error, { :invalid_reference, "restricted request" } }
            { :content, error, { request, _ } } -> format_http_error(error, request, "retrieve content")
        end
    end

    @doc """
      See if two references are alike.

      This will only consider two references alike if they both produce the same
      HTTP request (including options and headers).
    """
    @impl Resx.Producer
    def alike?(a, b) do
        with { :a, { :ok, { request, _ } } } <- { :a, to_request(a, []) },
             { :b, { :ok, { ^request, _ } } } <- { :b, to_request(b, []) } do
                true
        else
            _ -> false
        end
    end

    @impl Resx.Producer
    def source(reference) do
        case to_request(reference, []) do
            { :ok, _ } -> { :ok, nil }
            error -> error
        end
    end

    @impl Resx.Producer
    def resource_uri(reference) do
        case to_request(reference, []) do
            { :ok, { %{ url: url }, _ } } -> { :ok, url }
            error -> error
        end
    end

    @impl Resx.Producer
    def resource_attributes(reference) do
        case to_request(reference, []) do
            { :ok, { _, headers } } -> { :ok, headers }
            error -> error
        end
    end
end
