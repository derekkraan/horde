defmodule Horde.Tracker do
  @moduledoc """
  Provides public functions to join and leave hordes.
  """

  @doc """
  Join two hordes into one big horde. Calling this once will inform every node in each horde of every node in the other horde.
  """
  def join_hordes(horde, other_horde) do
    GenServer.cast(horde, {:join_horde, other_horde})
  end

  @doc """
  Remove an instance of horde from the greater hordes.
  """
  def leave_hordes(horde) do
    GenServer.cast(horde, :leave_hordes)
  end

  @doc """
  Get the members (nodes) of the horde
  """
  def members(horde) do
    GenServer.call(horde, :members)
  end
end
