defmodule PatchAuth do
  def get_auth_str(id) do
    auth = %{
      "type" => "auth",
      "id" => id,
      "passkey" => "08416EB34E46FD01C0E03B5E9B4AEACC06306F16D3E380559BBBAD8323C82A13"
    }
    Jason.encode!(auth) <> "\n"
  end
end
