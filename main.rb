require 'bundler'
Bundler.require

require 'active_support/all'
require 'trello'
require 'slack'
require 'yaml'
require 'erb'
require 'thor'

class OptimizelyNotifyCLI < Thor
  option :config, aliases: :c, default: './config.yml'
  desc '', 'fetch the results from Optimizely and notify to Slack.'
  def execute
    config = YAML.load(File.read(options[:config]))

    config[:target_projects].each do |target_project|
      Slack.configure { |c| c.token = config[:slack_tokens][target_project[:slack_token_ref]] }
      optimizely = Optimizely.new(api_token: config[:optimizely_tokens][target_project[:optimizely_token_ref]])

      optimizely_projects = optimizely.projects

      target_project_name = target_project[:project_name]
      if target_project_name.present?
        optimizely_projects = optimizely_projects.select { |p| target_project_name == p.project_name }
      end

      next if optimizely_projects.empty?

      goal_status_icons = target_project[:goal_status_icons]
      variation_names = {}
      goal_names = {}

      optimizely_projects.each do |project|
        experiment_messages = optimizely
          .experiments(project.id)
          .select { |e| e['status'] == 'Running' }
          .flat_map do |e|
            experiment_id = e.id
            baseline_id = nil
            map = optimizely.stats(experiment_id).each_with_object({}) do |s, m|
              variation_id = s.variation_id
              goal_id = s.goal_id
              baseline_id = s.baseline_id

              variation_names[variation_id] = s['variation_name']
              goal_names[goal_id] = s['goal_name']

              values = m.fetch(variation_id, {})
              values[goal_id] = s
              m[variation_id] = values
            end

            variation_message = map
              .sort { |a, b| (baseline_id == a[0]) ? -1 : ((baseline_id == b[0]) ? 1 : Integer(a[0]) - Integer(b[0])) }
              .map do |k, v|
                goal_message = v.sort.map do |goal_id, s|
                  <<~MESSAGE
                  #{goal_status_icons[s['status']]}#{goal_names[goal_id]}
                  CVR #{"%.2f" % (s['conversion_rate'] * 100)}%#{s['status'] != 'baseline' ? "(有意性確定まで#{s['visitors_until_statistically_significant']}人)" : ''}
                  MESSAGE
                end.join
                <<~MESSAGE
                ■#{variation_names[k]}
                #{goal_message}
                MESSAGE
              end.join
            <<~MESSAGE
              ```
              実験名: #{e['description']}
              開始日: #{e['last_modified'].to_date} (#{(Date.current - e['last_modified'].to_date).to_i}日経過)
              #{e['details']}
              結果URL: #{e['shareable_results_link']}
              対象URL:
              #{e['url_conditions'].map { |url| '  ' + url['value'] }.join("\n")}
              #{variation_message}
              ```
            MESSAGE
        end

        Slack::Client.new.tap do |client|
          experiment_messages.each do |message|
            client.chat_postMessage(
              username: "Optimizely通知(#{project['project_name']})",
              as_user: false,
              channel: target_project[:channel],
              text: message,
              icon_emoji: target_project[:icon_emoji],
            )
          end
        end
      end
    end
  end
end
OptimizelyNotifyCLI.start(ARGV)
