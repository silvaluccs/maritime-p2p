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
    defstruct [:type, :from, :to, :clock, :priority]

    @type t :: %__MODULE__{
            type: :reply,
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
end
