defmodule Constellation.Games.Categories do
  @moduledoc """
  Manages game categories and their selection for each round.
  """

  @doc """
  Returns the full list of available categories with their weights.
  Higher weight means higher probability of selection.
  """
  def all_categories do
    [
      %{name: "Animal", weight: 5},
      %{name: "Country", weight: 5},
      %{name: "Food/Drink", weight: 5},
      %{name: "Occupation", weight: 4},
      %{name: "City", weight: 4},
      %{name: "Boy's Name", weight: 4},
      %{name: "Girl's Name", weight: 4},
      %{name: "Fashion Brand", weight: 3},
      %{name: "Movie", weight: 3},
      %{name: "Clothing Item", weight: 3},
      %{name: "Nature Thing", weight: 3},
      %{name: "Sport", weight: 3},
      %{name: "Kitchen Item", weight: 2},
      %{name: "Musical Instrument", weight: 2},
      %{name: "Famous Person", weight: 2},
      %{name: "TV Show", weight: 2},
      %{name: "Something You Shout", weight: 1},
      %{name: "Car Brand", weight: 1},
      %{name: "Tool", weight: 1},
      %{name: "Fruit/Vegetable", weight: 3}
    ]
  end

  @doc """
  Selects initial categories for the first round.
  
  ## Parameters
    - count: Number of categories to select
  """
  def select_initial_categories(count \\ 4) do
    all_categories()
    |> weighted_random_selection(count)
    |> Enum.map(& &1.name)
  end

  @doc """
  Updates the categories for the next round:
  - Removes one random category from the current set
  - Adds one random category from the unused pool (weighted by probability)
  
  ## Parameters
    - current_categories: List of category names currently in use
  """
  def update_categories_for_next_round(current_categories) when is_list(current_categories) do
    # Convert current categories to a set for faster lookups
    current_set = MapSet.new(current_categories)
    
    # Get all categories as a map for easy lookup
    all_cats = all_categories()
    _all_names = Enum.map(all_cats, & &1.name)
    
    # Find unused categories (those not in current_set)
    unused_categories = Enum.filter(all_cats, fn cat -> 
      not MapSet.member?(current_set, cat.name)
    end)
    
    # Remove one random category from current set
    [removed_category] = Enum.take_random(current_categories, 1)
    remaining_categories = current_categories -- [removed_category]
    
    # Select one random category from unused pool (weighted)
    [new_category] = weighted_random_selection(unused_categories, 1)
    
    # Return updated list of categories
    remaining_categories ++ [new_category.name]
  end

  @doc """
  Performs weighted random selection from a list of items with weights.
  
  ## Parameters
    - items: List of maps, each containing a :weight key
    - count: Number of items to select
  """
  def weighted_random_selection(items, count) do
    # Calculate total weight
    total_weight = Enum.reduce(items, 0, fn item, acc -> acc + item.weight end)
    
    # Select 'count' items with weighted probability
    Enum.reduce(1..count, {items, []}, fn _, {remaining, selected} ->
      {chosen, new_remaining} = select_one_weighted(remaining, total_weight)
      _new_total = total_weight - chosen.weight
      {new_remaining, [chosen | selected]}
    end)
    |> elem(1)
  end
  
  # Helper to select one item based on weight
  defp select_one_weighted(items, total_weight) do
    # Generate random number between 0 and total_weight
    random = :rand.uniform() * total_weight
    
    # Find the item that corresponds to this random value
    Enum.reduce_while(items, {nil, random}, fn item, {_, remaining_weight} ->
      new_remaining = remaining_weight - item.weight
      if new_remaining <= 0 do
        {:halt, {item, new_remaining}}
      else
        {:cont, {item, new_remaining}}
      end
    end)
    |> case do
      {chosen, _} -> 
        {chosen, List.delete(items, chosen)}
    end
  end
end
