defmodule Core.Protocol do
  @moduledoc """
  Modulo para os protocolos de comunicação entre setores e drones. Define as estruturas de mensagens e os tipos de mensagens que podem ser trocados entre os setores e drones.
   - `Message`: Estrutura de mensagem para comunicação entre setores e drones, contendo o tipo da mensagem, o remetente e o payload (dados) da mensagem.
  """
  defmodule Request do
    @moduledoc """
      Modulo para representar uma requisição de acesso à seção crítica.
      Contém o tipo da mensagem, o remetente, o destinatário, o timestamp lógico e a prioridade da requisição.
    """
    @derive JSON.Encoder
    defstruct [:type, :from, :to, :clock, :priority]

    @type t :: %__MODULE__{
            type: :request,
            from: String.t(),
            to: String.t(),
            clock: non_neg_integer(),
            priority: non_neg_integer()
          }
    def from_map(%{
          "type" => type,
          "from" => from,
          "to" => to,
          "clock" => clock,
          "priority" => priority
        }) do
      {:ok,
       %__MODULE__{
         type: String.to_existing_atom(type),
         from: from,
         to: to,
         clock: clock,
         priority: priority
       }}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule Reply do
    @moduledoc """
      Modulo para representar uma resposta a uma requisição de acesso à seção crítica.
      Contém o tipo da mensagem, o remetente e o destinatário.
    """
    @derive JSON.Encoder
    defstruct [:type, :from, :to, :clock, :priority, :request_ts]

    @type t :: %__MODULE__{
            type: :reply,
            from: String.t(),
            to: String.t(),
            clock: non_neg_integer(),
            priority: non_neg_integer(),
            request_ts: non_neg_integer() | nil
          }
    def from_map(%{
          "type" => type,
          "from" => from,
          "to" => to,
          "clock" => clock,
          "priority" => priority,
          "request_ts" => request_ts
        }) do
      {:ok,
       %__MODULE__{
         type: String.to_existing_atom(type),
         from: from,
         to: to,
         clock: clock,
         priority: priority,
         request_ts: request_ts
       }}
    end

    def from_map(%{
          "type" => type,
          "from" => from,
          "to" => to,
          "clock" => clock,
          "priority" => priority
        }) do
      {:ok,
       %__MODULE__{
         type: String.to_existing_atom(type),
         from: from,
         to: to,
         clock: clock,
         priority: priority,
         request_ts: nil
       }}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule Message do
    @moduledoc """
    Estrutura de mensagem para comunicação entre setores e drones.
    """
    @derive JSON.Encoder
    defstruct [:type, :from, :payload]

    @type t :: %__MODULE__{
            type: :ping | :pong,
            from: String.t(),
            payload: any()
          }
    @doc "Converte um mapa (vindo do JSON) para o struct Message."
    def from_map(%{"type" => type, "from" => from, "payload" => payload}) do
      {:ok,
       %__MODULE__{
         type: String.to_existing_atom(type),
         from: from,
         payload: payload
       }}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule Auth do
    @moduledoc """
    Mensagem de autenticação usando uma passkey criptografada (hash SHA256).
    """
    @derive JSON.Encoder
    defstruct [:type, :id, :passkey]

    def from_map(%{"type" => "auth", "id" => id, "passkey" => passkey}) do
      {:ok, %__MODULE__{type: :auth, id: id, passkey: passkey}}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule DroneStatus do
    @moduledoc "Mensagem enviada pelo drone para informar seu status aos setores."
    @derive JSON.Encoder
    defstruct [:type, :drone_id, :status]

    def from_map(%{"type" => "drone_status", "drone_id" => drone_id, "status" => status}) do
      {:ok, %__MODULE__{type: :drone_status, drone_id: drone_id, status: status}}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule Mission do
    @moduledoc """
    Mensagem enviada por um setor para alocar um drone para uma missão.
    Agora inclui `mission_name` e `clock` para que o drone possa ecoá-los
    de volta no MissionReject, preservando o clock original.
    """
    @derive JSON.Encoder
    defstruct [:type, :drone_id, :from, :mission_name, :clock]

    def from_map(%{"type" => "mission", "drone_id" => drone_id, "from" => from} = map) do
      {:ok,
       %__MODULE__{
         type: :mission,
         drone_id: drone_id,
         from: from,
         mission_name: Map.get(map, "mission_name"),
         clock: Map.get(map, "clock")
       }}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule MissionAck do
    @moduledoc """
    Confirmação enviada pelo drone ao setor quando aceita uma missão (estava IDLE).
    O setor só chama :exit_critical_section após receber este ACK.
    """
    @derive JSON.Encoder
    defstruct [:type, :drone_id, :to]

    def from_map(%{"type" => "mission_ack", "drone_id" => drone_id, "to" => to}) do
      {:ok, %__MODULE__{type: :mission_ack, drone_id: drone_id, to: to}}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule MissionReject do
    @moduledoc """
    Rejeição enviada pelo drone ao setor quando recebe uma missão mas já está BUSY.
    Contém `mission_name` e `clock` originais para que o setor possa re-enfileirar
    a missão com prioridade 2 sem perder o clock lógico.
    """
    @derive JSON.Encoder
    defstruct [:type, :drone_id, :to, :mission_name, :clock]

    def from_map(%{
          "type" => "mission_reject",
          "drone_id" => drone_id,
          "to" => to,
          "mission_name" => mission_name,
          "clock" => clock
        }) do
      {:ok,
       %__MODULE__{
         type: :mission_reject,
         drone_id: drone_id,
         to: to,
         mission_name: mission_name,
         clock: clock
       }}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule SensorStatus do
    @moduledoc "Mensagem enviada pelo sensor para registrar/informar status ao setor."
    @derive JSON.Encoder
    defstruct [:type, :sensor_id, :status]

    def from_map(%{"type" => "sensor_status", "sensor_id" => sensor_id, "status" => status}) do
      {:ok, %__MODULE__{type: :sensor_status, sensor_id: sensor_id, status: status}}
    end

    def from_map(_), do: {:error, :invalid_message}
  end

  defmodule SensorRequest do
    @moduledoc "Mensagem enviada pelo sensor solicitando que o setor enfileire um pedido de missão."
    @derive JSON.Encoder
    defstruct [:type, :sensor_id, :priority, :reason]

    def from_map(%{
          "type" => "sensor_request",
          "sensor_id" => sensor_id,
          "priority" => priority,
          "reason" => reason
        }) do
      {:ok,
       %__MODULE__{
         type: :sensor_request,
         sensor_id: sensor_id,
         priority: priority,
         reason: reason
       }}
    end

    def from_map(_), do: {:error, :invalid_message}
  end
end
