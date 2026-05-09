defmodule Sector.Shell do
  @moduledoc """
  Interface simples para interagir com o nó no terminal do IEx.
  """

  def request do
    Sector.Node.request_mission()
  end

  def queue do
    queue = Sector.Node.get_queue()

    if queue == [] do
      IO.puts("\n=== [SHELL] Fila de requisições está vazia. ===")
    else
      IO.puts("\n=== [SHELL] Fila Atual ===")

      Enum.each(queue, fn {priority, name, ts, status} ->
        IO.puts("Missão: #{name} | Prioridade: #{priority} | TS: #{ts} | Status: #{status}")
      end)
    end
  end

  def help do
    IO.puts("""

    === COMANDOS DO SHELL DO SETOR ===
    request - Cria uma requisição para a seção crítica/drone.
    queue   - Visualiza a fila de requisições.
    help    - Mostra essa mensagem de ajuda.
    exit    - Encerra o nó.
    ==================================
    """)
  end

  def start do
    # Aguarda 1 segundo para não misturar com os logs de inicialização
    Process.sleep(1000)

    IO.puts("""

    ============================================
               MARITIME P2P - SECTOR
    ============================================
    Pronto! O nó está rodando.
    Digite 'help' para ver os comandos.
    """)

    loop()
  end

  def loop do
    data = IO.gets("sector-shell> ")

    if data != :eof do
      case String.trim(data) do
        "request" -> request()
        "queue" -> queue()
        "help" -> help()
        "exit" -> System.halt(0)
        "" -> :ok
        # Ignora lixos do terminal ANSI como setas (up/down/left/right)
        "\e" <> _ -> :ok
        _ -> IO.puts("Comando inválido. Digite 'help'.")
      end

      loop()
    end
  end
end
