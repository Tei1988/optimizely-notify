require 'bundler'
Bundler.require

require 'active_support/all'
require 'trello'
require 'slack'
require 'yaml'
require 'erb'
require 'thor'

require 'pp'

class OptimizelyExperiment
  include Virtus.model

  attribute :optimizely, Optimizely::Engine
  attribute :config, Hash
  attribute :project, Optimizely::Project
  attribute :experiment, Optimizely::Experiment

  def goal_name(goal_id)
    @goal_names[goal_id]
  end

  def variation_name(variation_id)
    @variation_names[variation_id]
  end

  def stats
    @stats ||= {}.tap do |stats|
      variation_names = {}
      goal_names = {}
      optimizely.stats(experiment.id).each_with_object(stats) do |s, m|
        variation_id = s.variation_id
        goal_id = s.goal_id
        baseline_id = s.baseline_id

        variation_names[variation_id] = s['variation_name']
        goal_names[goal_id] = s['goal_name']

        values = m.fetch(goal_id, {})
        values[variation_id] = s
        m[goal_id] = values
      end
      @goal_names = goal_names
      @variation_names = variation_names
    end
  end
end

class Helper
  def self.judge(stats)
    stats.values
      .select { |s| s['status'] != 'baseline' }
      .map { |s| s['status'] }
      .first || 'baseline'
  end
  def self.sort(t)
    baseline_id = t.values.select { |s| s['status'] == 'baseline' }.first['baseline_id']
    t.sort { |a, b| (baseline_id == a[0]) ? -1 : ((baseline_id == b[0]) ? 1 : Integer(a[0]) - Integer(b[0])) }
  end
  def self.url_conditions(e)
    e['url_conditions'].map { |url| url['value'] }.join('\n')
  end
end

class OptimizelyNotifyCLI < Thor
  option :config, aliases: :c, default: './config.yml'
  desc 'execute', 'fetch the results from Optimizely and notify to Slack.'

  def execute
    config[:target_projects].each do |target_project|
      Slack.configure { |c| c.token = config[:slack_tokens][target_project[:slack_token_ref]] }
      optimizely = Optimizely.new(api_token: config[:optimizely_tokens][target_project[:optimizely_token_ref]])
      Retryable.retryable(tries: 3, sleep: 5) do
        projects(optimizely, target_project).each do |project|
          Retryable.retryable(tries: 3, sleep: 5) do
            optimizely.experiments(project.id).select { |e| e['status'] == 'Running' }
            .each do |experiment|
              Retryable.retryable(tries: 3, sleep: 5) do
                e = OptimizelyExperiment.new(optimizely: optimizely, config: target_project, project: project, experiment: experiment)
                object = JSON.parse(ERB.new(File.read("templates/#{target_project[:template_filepath]}"), nil, '-').result(binding), symbolize_names: true)
                object[:attachments] = object[:attachments].to_json
                Slack::Client.new.tap do |client|
                  pp client.chat_postMessage(object)
                end
              end
            end
          end
        end
      end
    end
  end

  private

  def initialize(*params)
    super(*params)
  end

  def config
    @config ||= YAML.load(File.read(options[:config]))
  end

  def projects(optimizely, target_project)
    target_project_name = target_project[:project_name]
    optimizely.projects
      .select { |p| target_project_name.blank? || (target_project_name == p.project_name) }
  end
end
OptimizelyNotifyCLI.start(ARGV)
