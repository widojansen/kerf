defmodule Kerf.ServiceHealth.Context do
  @moduledoc """
  Typed, lenient representation of the izi monitoring `health-context` payload.

  Known fields are modeled as typed struct fields with documented defaults.
  Any unmodeled key is preserved losslessly in a `raw` map, never dropped and
  never errored on. A missing known field degrades to its default rather than
  raising, so an upstream payload change does not take the pipeline down.
  See `docs/specs/SPEC_01_HEALTH_CLIENT.md`.
  """

  alias __MODULE__.{Current, Baseline}

  @known_keys ~w(status is_anomalous anomalies alerts current baseline)

  @type t :: %__MODULE__{
          status: String.t(),
          is_anomalous: boolean(),
          anomalies: list(),
          alerts: list(),
          current: Current.t(),
          baseline: Baseline.t(),
          raw: map()
        }

  defstruct status: "unknown",
            is_anomalous: false,
            anomalies: [],
            alerts: [],
            current: nil,
            baseline: nil,
            raw: %{}

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      status: Map.get(map, "status", "unknown"),
      is_anomalous: Map.get(map, "is_anomalous", false),
      anomalies: Map.get(map, "anomalies", []),
      alerts: Map.get(map, "alerts", []),
      current: Current.from_map(Map.get(map, "current") || %{}),
      baseline: Baseline.from_map(Map.get(map, "baseline") || %{}),
      raw: Map.drop(map, @known_keys)
    }
  end

  defmodule Queues do
    @moduledoc "Queue counters under `current.queues`."

    @type t :: %__MODULE__{
            total: integer(),
            healthy: integer(),
            at_ceiling: integer(),
            high_wait: integer()
          }

    defstruct total: 0, healthy: 0, at_ceiling: 0, high_wait: 0

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        total: Map.get(map, "total", 0),
        healthy: Map.get(map, "healthy", 0),
        at_ceiling: Map.get(map, "at_ceiling", 0),
        high_wait: Map.get(map, "high_wait", 0)
      }
    end
  end

  defmodule Current do
    @moduledoc "The `current` snapshot. `raw` carries `web` and any unmodeled keys."

    alias Kerf.ServiceHealth.Context.Queues

    @known_keys ~w(queues request_rps service_error_rate)

    @type t :: %__MODULE__{
            queues: Queues.t(),
            request_rps: number(),
            service_error_rate: number(),
            raw: map()
          }

    defstruct queues: nil, request_rps: 0, service_error_rate: 0, raw: %{}

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        queues: Queues.from_map(Map.get(map, "queues") || %{}),
        request_rps: Map.get(map, "request_rps", 0),
        service_error_rate: Map.get(map, "service_error_rate", 0),
        raw: Map.drop(map, @known_keys)
      }
    end
  end

  defmodule Baseline do
    @moduledoc "The `baseline` snapshot. `raw` carries `maximums` and any unmodeled keys."

    @known_keys ~w(requests services jobs)

    @type t :: %__MODULE__{
            requests: map(),
            services: map(),
            jobs: map(),
            raw: map()
          }

    defstruct requests: %{}, services: %{}, jobs: %{}, raw: %{}

    @spec from_map(map()) :: t()
    def from_map(map) when is_map(map) do
      %__MODULE__{
        requests: Map.get(map, "requests", %{}),
        services: Map.get(map, "services", %{}),
        jobs: Map.get(map, "jobs", %{}),
        raw: Map.drop(map, @known_keys)
      }
    end
  end
end
