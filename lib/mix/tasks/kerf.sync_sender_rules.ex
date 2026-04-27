defmodule Mix.Tasks.Kerf.SyncSenderRules do
  @shortdoc "Sync sender rules from Python pipeline into email_senders table"
  @moduledoc """
  Upserts sender pattern rules into the email_senders table for FastClassifier.
  Patterns are matched case-insensitively against the From field.

  ## Usage

      MIX_ENV=prod mix kerf.sync_sender_rules
      MIX_ENV=prod mix kerf.sync_sender_rules --dry-run
  """
  use Mix.Task

  import Ecto.Query

  # Ported from ~/Projects/incoming-mail/incoming_mail.py SENDER_RULES + PRIORITY_SENDERS
  # Plus new patterns discovered from unmatched backlog emails.
  # Format: {pattern, category, priority_override \\ nil, is_priority \\ false}
  @sender_rules [
    # === Priority senders ===
    {"fource", "business", 5, true},
    {"izimotive", "business", 5, true},
    {"diana", "personal", 5, true},
    {"lahdoudi", "personal", 5, true},
    {"bob", "personal", 5, true},
    {"spierenburg", "personal", 5, true},
    {"mary.elsa5@gmail.com", "personal", 5, true},
    {"example-law.test", "business", 5, true},
    {"charlie", "personal", 5, true},
    {"smeets@vha", "business", 5, true},
    {"zusterzeel", "personal", 5, true},
    {"example-firm.nl", "business", 5, true},

    # === Publications ===
    {"changelog.com", "newsletter", nil, false},
    {"theneuron", "newsletter", nil, false},
    {"theaireport", "newsletter", nil, false},
    {"thenewstack", "newsletter", nil, false},
    {"turingpost", "newsletter", nil, false},
    {"technologyreview.com", "newsletter", nil, false},
    {"computerworld.com", "newsletter", nil, false},
    {"wired.com", "newsletter", nil, false},
    {"venturebeat.com", "newsletter", nil, false},
    {"semafor.com", "newsletter", nil, false},
    {"economist.com", "newsletter", nil, false},
    {"engelsbergideas.com", "newsletter", nil, false},
    {"atlasobscura.com", "newsletter", nil, false},
    {"techrepublic.com", "newsletter", nil, false},
    {"codepen.io", "newsletter", nil, false},
    {"hubspot.com", "newsletter", nil, false},
    {"nvidia.com", "newsletter", nil, false},
    {"darkreading.com", "newsletter", nil, false},
    {"networkcomputing.com", "newsletter", nil, false},
    {"sciencex.com", "newsletter", nil, false},
    {"headway", "newsletter", nil, false},
    {"prototypr.io", "newsletter", nil, false},
    {"indiehackers.com", "newsletter", nil, false},
    {"entrepreneur.com", "newsletter", nil, false},
    {"quantamagazine.org", "newsletter", nil, false},
    {"science.org", "newsletter", nil, false},
    {"tech.eu", "newsletter", nil, false},
    {"etfcoach", "newsletter", nil, false},
    {"thesequence", "newsletter", nil, false},
    {"cobusgreyling", "newsletter", nil, false},
    {"thewhitebox.ai", "newsletter", nil, false},
    {"superhuman_at_mail", "newsletter", nil, false},
    {"joinsuperhuman.ai", "newsletter", nil, false},
    {"codingbeautydev", "newsletter", nil, false},
    {"nytimes.com", "newsletter", nil, false},
    {"thehustle.co", "newsletter", nil, false},
    {"readthejoe.com", "newsletter", nil, false},
    {"cnn.com", "newsletter", nil, false},
    {"theresanaiforthat.com", "newsletter", nil, false},
    {"ayushchat.com", "newsletter", nil, false},
    {"emailcopywriter.com", "newsletter", nil, false},
    {"@medium.com", "newsletter", nil, false},
    {"@substack.com", "newsletter", nil, false},
    {"axios.com", "newsletter", nil, false},
    {"infoworld.com", "newsletter", nil, false},
    {"deeplearning.ai", "newsletter", nil, false},
    {"morningbrew.com", "newsletter", nil, false},
    {"politico.eu", "newsletter", nil, false},
    {"politico.co.uk", "newsletter", nil, false},
    {"politico.com", "newsletter", nil, false},
    {"datatalks.club", "newsletter", nil, false},
    {"theknowledge.com", "newsletter", nil, false},
    {"techcrunch.com", "newsletter", nil, false},
    {"ibm.com", "newsletter", nil, false},
    {"sueddeutsche.de", "newsletter", nil, false},
    {"platformer.news", "newsletter", nil, false},
    {"theguardian.com", "newsletter", nil, false},
    {"sinocism.com", "newsletter", nil, false},
    {"foundingjourney.com", "newsletter", nil, false},
    {"theconversation.com", "newsletter", nil, false},
    {"foreignaffairs.com", "newsletter", nil, false},
    {"noemamag.com", "newsletter", nil, false},
    {"futureparty.com", "newsletter", nil, false},
    {"vox.com", "newsletter", nil, false},
    {"generativeai.net", "newsletter", nil, false},
    {"ollama.com", "newsletter", nil, false},
    {"getsaasweekly.com", "newsletter", nil, false},
    {"join1440.com", "newsletter", nil, false},
    {"markmanson.net", "newsletter", nil, false},
    {"caixabankresearch.com", "newsletter", nil, false},
    {"tailscale.com", "newsletter", nil, false},
    {"beehiiv.com", "newsletter", nil, false},
    {"@icloud.com", "newsletter", nil, false},
    {"aaas.sciencepubs.org", "newsletter", nil, false},
    {"thenextweb.com", "newsletter", nil, false},
    {"aitoolreport.com", "newsletter", nil, false},
    {"thetechoasis.com", "newsletter", nil, false},
    {"press.princeton.edu", "newsletter", nil, false},
    {"santafe.edu", "newsletter", nil, false},
    {"qz.com", "newsletter", nil, false},
    {"meduza.io", "newsletter", nil, false},
    {"sitepoint.com", "newsletter", nil, false},
    {"makeuseof.com", "newsletter", nil, false},
    {"mailchimpapp.com", "newsletter", nil, false},
    {"dezeen.com", "newsletter", nil, false},
    {"decorrespondent.nl", "newsletter", nil, false},
    {"parlement.com", "newsletter", nil, false},
    {"ghost.io", "newsletter", nil, false},
    {"bryancollins.com", "newsletter", nil, false},
    {"bellingcat.com", "newsletter", nil, false},
    {"crewai.discoursemail.com", "newsletter", nil, false},
    {"rasa.com", "newsletter", nil, false},
    {"stackshare.io", "newsletter", nil, false},
    {"gzeromedia.com", "newsletter", nil, false},
    {"defenseone.com", "newsletter", nil, false},
    {"maartendepodcast.nl", "newsletter", nil, false},
    {"theatlantic.com", "newsletter", nil, false},
    {"nzz.ch", "newsletter", nil, false},
    {"evakeiffenheim.com", "newsletter", nil, false},
    {"zdf.de", "newsletter", nil, false},
    {"cntraveler.com", "newsletter", nil, false},
    {"email.claude.com", "newsletter", nil, false},
    {"logto.io", "newsletter", nil, false},
    {"eoswetenschap.eu", "newsletter", nil, false},
    {"next-mobility.de", "newsletter", nil, false},
    {"ittnewsletter.com", "newsletter", nil, false},
    {"getthefuturist.com", "newsletter", nil, false},
    {"elektronikpraxis.de", "newsletter", nil, false},
    {"krebsonsecurity.com", "newsletter", nil, false},
    {"foreignpolicy.com", "newsletter", nil, false},
    {"understandingwar.org", "newsletter", nil, false},
    {"euronews.com", "newsletter", nil, false},
    {"arte.tv", "newsletter", nil, false},
    {"overheid.nl", "newsletter", nil, false},
    {"physorg.com", "newsletter", nil, false},
    {"wordpress.com", "newsletter", nil, false},
    {"eff.org", "newsletter", nil, false},
    {"torproject.org", "newsletter", nil, false},
    {"indiegogo.com", "newsletter", nil, false},
    {"springernature.com", "newsletter", nil, false},

    # === Learning ===
    {"hashmerge.com", "newsletter", nil, false},
    {"elixir-lang.org", "newsletter", nil, false},
    {"elixirforum.com", "newsletter", nil, false},
    {"elixir-radar.com", "newsletter", nil, false},
    {"curiosum.com", "newsletter", nil, false},
    {"grox.io", "newsletter", nil, false},
    {"flaviocopes.com", "newsletter", nil, false},
    {"freecodecamp.org", "newsletter", nil, false},
    {"pragprog.com", "newsletter", nil, false},
    {"pragmaticstudio", "newsletter", nil, false},
    {"scrimba.com", "newsletter", nil, false},
    {"kirupa.com", "newsletter", nil, false},
    {"pyimagesearch.com", "newsletter", nil, false},
    {"learnopencv.com", "newsletter", nil, false},
    {"codeproject.com", "newsletter", nil, false},
    {"londonappbrewery.com", "newsletter", nil, false},
    {"mit.edu", "newsletter", nil, false},
    {"udemy.com", "newsletter", nil, false},
    {"bbcmaestro.com", "newsletter", nil, false},
    {"sdsa.ai", "newsletter", nil, false},
    {"astronomer.io", "newsletter", nil, false},
    {"resend.com", "newsletter", nil, false},
    {"ayothewriter.com", "newsletter", nil, false},

    # === Transactional ===
    {"noreply@github.com", "transactional", nil, false},
    {"notifications@github.com", "transactional", nil, false},
    {"gitlab.com", "transactional", nil, false},
    {"jetbrains.com", "transactional", nil, false},
    {"ziggo.nl", "transactional", nil, false},
    {"ziggo.com", "transactional", nil, false},
    {"eneco.nl", "transactional", nil, false},
    {"eneco.com", "transactional", nil, false},
    {"anwb.nl", "transactional", nil, false},
    {"consumentenbond.nl", "transactional", nil, false},
    {"infomedics", "transactional", nil, false},
    {"ennatuurlijk", "transactional", nil, false},
    {"worldstream", "transactional", nil, false},
    {"cz.nl", "transactional", nil, false},
    {"apple.com", "transactional", nil, false},
    {"izimotive.nl", "transactional", nil, false},
    {"izimotive.com", "transactional", nil, false},
    {"revolut.com", "transactional", nil, false},
    {"netflix.com", "transactional", nil, false},
    {"ovhcloud.com", "transactional", nil, false},
    {"coralogix.com", "transactional", nil, false},

    # === Social / LinkedIn ===
    {"linkedin.com", "social", nil, false},

    # === Spam / Unsubscribe ===
    {"ourtime.com", "spam", nil, false},
    {"e-matching.nl", "spam", nil, false},
    {"lexa.nl", "spam", nil, false},
    {"lexa.email", "spam", nil, false},
    {"freelancer.com", "spam", nil, false},
    {"komoot.de", "spam", nil, false},
    {"dasgesundetier.de", "spam", nil, false},
    {"bollants.de", "spam", nil, false},
    {"vju-ruegen.de", "spam", nil, false},
    {"news-maerz.de", "spam", nil, false},
    {"tourismireland", "spam", nil, false},
    {"raus.life", "spam", nil, false},
    {"meet5", "spam", nil, false},
    {"tripadvisor.com", "spam", nil, false},
    {"flippa.com", "spam", nil, false},

    # === Personal ===
    {"museum.nl", "personal", nil, false},
    {"vanpiere.nl", "personal", nil, false},
    {"idagio.com", "personal", nil, false},
    {"today.renee@outlook.com", "personal", nil, false},
    {"operavision.eu", "personal", nil, false},
    {"operazuid.nl", "personal", nil, false},
    {"vpro.nl", "personal", nil, false},
    {"erik.vermeulen@example.be", "business", nil, true},
    {"former-colleague@example.com", "business", nil, true},

    # === Hotels ===
    {"hotel", "newsletter", nil, false},
    {"resort", "newsletter", nil, false},
    {"alpenhotel", "newsletter", nil, false},
    {"booking.com", "newsletter", nil, false},
    {"puradies.com", "newsletter", nil, false},
    {"deimann.de", "newsletter", nil, false},
    {"hotel-sackmann.de", "newsletter", nil, false},
    {"ahrenshoop.travel", "newsletter", nil, false},
    {"severins-sylt.de", "newsletter", nil, false},
    {"cloud7.de", "newsletter", nil, false},
    {"byway.travel", "newsletter", nil, false},

    # === E-Residency ===
    {"eresidency", "newsletter", nil, false},
  ]

  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: [dry_run: :boolean])
    dry_run = Keyword.get(opts, :dry_run, false)

    alias Kerf.KnowledgeBase.EmailSender

    {created, updated, skipped} =
      Enum.reduce(@sender_rules, {0, 0, 0}, fn {pattern, category, priority_override, is_priority}, {c, u, s} ->
        # Use a synthetic email as the unique key for pattern-based rules
        rule_email = "rule-#{:erlang.phash2(pattern)}@fast-classifier"

        existing = Kerf.Repo.one(from(s in EmailSender, where: s.email == ^rule_email))

        cond do
          dry_run ->
            action = if existing, do: "UPDATE", else: "CREATE"
            IO.puts("  #{action} #{pattern} -> #{category} (pri=#{priority_override || "default"}, priority=#{is_priority})")
            {c, u, s}

          existing ->
            changeset = EmailSender.changeset(existing, %{
              classification_override: category,
              match_pattern: pattern,
              is_priority: is_priority,
              priority_override: priority_override
            })

            if changeset.changes == %{} do
              {c, u, s + 1}
            else
              Kerf.Repo.update!(changeset)
              {c, u + 1, s}
            end

          true ->
            %EmailSender{}
            |> EmailSender.changeset(%{
              email: rule_email,
              name: "Rule: #{pattern}",
              domain: "fast-classifier",
              classification_override: category,
              match_pattern: pattern,
              is_priority: is_priority,
              priority_override: priority_override
            })
            |> Kerf.Repo.insert!()

            {c + 1, u, s}
        end
      end)

    if dry_run do
      IO.puts("\nDry run complete. #{length(@sender_rules)} rules checked.")
    else
      IO.puts("Sync complete: #{created} created, #{updated} updated, #{skipped} unchanged")
    end
  end
end
