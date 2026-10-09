defmodule AsyncWorlds.Discord.FailingHandler do
  @moduledoc false

  def execute(_, _), do: raise("private-command-content")
end
