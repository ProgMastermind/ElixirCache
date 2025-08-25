defmodule Server.Error do
  @moduledoc """
  Error returned by Redis.

  This exception represents semantic errors returned by Redis: for example,
  non-existing commands or operations on keys with the wrong type (`INCR
  not_an_integer`).
  """

  defexception [:message]

  @type t :: %__MODULE__{message: binary}
end
