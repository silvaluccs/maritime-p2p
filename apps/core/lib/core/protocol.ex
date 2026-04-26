defmodule Core.Protocol do
  @moduledoc """
  Modulo para os protocolos de comunicação entre setores e drones. Define as estruturas de mensagens e os tipos de mensagens que podem ser trocados entre os setores e drones.
   - `Message`: Estrutura de mensagem para comunicação entre setores e drones, contendo o tipo da mensagem, o remetente e o payload (dados) da mensagem.

  """

  defmodule Message do
    @moduledoc """
    Estrutura de mensagem para comunicação entre setores e drones.
    """

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
