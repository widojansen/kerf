defmodule Kerf.Eval.Manifest.Language do
  @moduledoc """
  SPEC_H F08.1 / A3.5 — stopword-ratio language heuristic used by the export
  (`language_source: "heuristic"`); the owner corrects it while labelling.

  The language whose stopwords make up the largest share of the words wins;
  no stopword at all, or a tie for first place, is `"und"`.
  """

  @stopwords %{
    "nl" => ~w(de het een en ik je jij u uw we wij ze zij hij is niet voor naar om al heb
               hebben van dat die dit deze op te met zijn er maar ook als bij of wat nog kan
               wel geen mijn aan uit door over dan was wordt worden graag bedankt groet),
    "de" => ~w(der die das den dem ein eine einen und ich du er sie es wir ihr uns ist sind
               nicht für mit auf zu von dass auch noch aber an so wie bei war wird werden
               haben habe kann mein mir schon nur oder im sich bitte danke grüße),
    "en" => ~w(the and is it not we i you he she they have has had for at can to of a an in
               that this be are on with as was will would please our your my me from by or
               if do but so thanks regards)
  }

  @spec guess(String.t()) :: String.t()
  def guess(text) when is_binary(text) do
    words = Regex.scan(~r/\p{L}+/u, String.downcase(text)) |> List.flatten()

    scores =
      for {lang, stopwords} <- @stopwords do
        {lang, Enum.count(words, &(&1 in stopwords))}
      end

    case Enum.sort_by(scores, &elem(&1, 1), :desc) do
      [{_, 0} | _] -> "und"
      [{_, top}, {_, top} | _] -> "und"
      [{lang, _} | _] -> lang
    end
  end

  def guess(_text), do: "und"
end
