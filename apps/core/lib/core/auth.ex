defmodule Core.Auth do
  @moduledoc """
  Lida com a geracao de hash para autenticacao.
  """

  def get_hashed_passkey do
    passkey = System.get_env("PASSKEY") || "default_maritime_passkey"
    :crypto.hash(:sha256, passkey) |> Base.encode16()
  end
end
