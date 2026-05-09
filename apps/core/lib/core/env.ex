defmodule Core.Env do
  @moduledoc """
  Modulo Compartilhado para pegar os ips e portas dos modulos a partir de uma variavel de ambiente
  """
  require Logger

  def get_hosts_from_env(variable) do
    get_hosts(variable)
    |> Enum.map(&parse_host/1)
    |> Enum.map(fn
      {:ok, host} -> host
      {:error, _} -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_hosts(variable) do
    System.get_env(variable, "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_host(host) do
    case String.split(host, ":") do
      [ip, port_str] ->
        case Integer.parse(port_str) do
          {port, ""} when port in 1..65_535 ->
            {:ok, {ip, port}}

          _ ->
            Logger.warning("Porta inválida ignorada: #{host}")
            {:error, :invalid_port}
        end

      _ ->
        Logger.warning("Formato de host inválido ignorado: #{host}")
        {:error, :invalid_host_format}
    end
  end
end
