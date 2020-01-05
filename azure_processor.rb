# frozen_string_literal: true

require 'dependabot/omnibus'

class AzureProcessor
  class Unathorized < StandardError; end
  class NotFound < StandardError; end

  def initialize(organisation, available_credentials)
    @organisation = organisation
    @available_credentials = available_credentials

    @api_endpoint = "https://dev.azure.com/#{organisation}"
    @organisation_credentials = available_credentials
                                .select { |cred| cred['type'] == 'git_source' }
                                .find { |cred| cred['host'] == 'dev.azure.com' }
  end

  def process
    puts "#{@organisation} => Fetch projects..."

    response = get("#{@api_endpoint}/_apis/projects")
    JSON.parse(response.body)
        .fetch('value')
        .map do |project|
          {
            id: project.fetch('id'),
            name: project.fetch('name')
          }
        end
        .each { |project| process_project(project) }
  end

  def process_project(project)
    puts "#{@organisation} => #{project[:name]} => Checking repositories..."

    response_repos = get("#{@api_endpoint}/#{project[:id]}/_apis/git/repositories")
    JSON.parse(response_repos.body)
        .fetch('value')
        .map do |repo|
          {
            id: repo.fetch('id'),
            name: repo.fetch('name')
          }
        end
        .each { |repo| process_repo(project, repo) }
  end

  def process_repo(project, repo)
    begin
      puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => Checking for Depenadbot configuration file..."

      response_config = get("#{@api_endpoint}/#{project[:id]}/_apis/git/repositories/#{repo[:id]}/items?path=.dependabot/config.yml")
      config = YAML.safe_load(response_config.body)

      config['update_configs']
        .each { |update_config| process_dependency(project, repo, update_config) }
    rescue NotFound
      generate_bug_dependabotconfig(project, repo)
    end

    begin
      puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => Checking for Azure Pipeline configuration file..."

      get("#{@api_endpoint}/#{project[:id]}/_apis/git/repositories/#{repo[:id]}/items?path=azure-pipelines.yml")
    rescue NotFound
      generate_bug_azurepipeline(project, repo)
    end
  end

  def generate_bug_dependabotconfig(project, repo)
    puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => Depenadbot configuration file does not exist, raising bug if required..."

    bug_title = "[#{repo[:name]}] Configure Dependabot"
    query = { query: "Select [System.Id] From WorkItems Where [System.Title] = '#{bug_title}'" }
    find = post("#{@api_endpoint}/#{project[:id]}/_apis/wit/wiql?api-version=5.0", query.to_json)
    unless JSON.parse(find.body).fetch('workItems').any?
      content = [
        {
          op: 'add',
          path: '/fields/System.Title',
          from: '',
          value: bug_title
        },
        {
          op: 'add',
          path: '/fields/System.Tags',
          from: '',
          value: 'Dependabot'
        },
        {
          op: 'add',
          path: '/fields/Microsoft.VSTS.TCM.ReproSteps',
          from: '',
          value: "Please add `.dependabot/config.yml` to the default branch of the `#{repo[:name]}` repo." \
                  '<p>This will automatically configure the Dependabot service to provide dependency updates.</p>' \
                  '<p>See <a href="https://dependabot.com/docs/config-file">https://dependabot.com/docs/config-file</a> for more information.</p>'
        },
        {
          op: 'add',
          path: '/fields/Microsoft.VSTS.Common.Priority',
          from: '',
          value: '1'
        },
        {
          op: 'add',
          path: '/fields/Microsoft.VSTS.Common.Severity',
          from: '',
          value: '1 - Critical'
        }
      ]
      post_patch("#{@api_endpoint}/#{project[:id]}/_apis/wit/workitems/$Bug?api-version=5.0", content.to_json)
    end
  end

  def generate_bug_azurepipeline(project, repo)
    puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => Azure Pipeline configuration file does not exist, raising bug if required..."

    bug_title = "[#{repo[:name]}] Configure Azure Pipeline"
    query = { query: "Select [System.Id] From WorkItems Where [System.Title] = '#{bug_title}'" }
    find = post("#{@api_endpoint}/#{project[:id]}/_apis/wit/wiql?api-version=5.0", query.to_json)
    unless JSON.parse(find.body).fetch('workItems').any?
      content = [
        {
          op: 'add',
          path: '/fields/System.Title',
          from: '',
          value: bug_title
        },
        {
          op: 'add',
          path: '/fields/System.Tags',
          from: '',
          value: 'Azure Pipeline'
        },
        {
          op: 'add',
          path: '/fields/Microsoft.VSTS.TCM.ReproSteps',
          from: '',
          value: "Please add `azure-pipelines.yml` to the default branch of the `#{repo[:name]}` repo."
        },
        {
          op: 'add',
          path: '/fields/Microsoft.VSTS.Common.Priority',
          from: '',
          value: '1'
        },
        {
          op: 'add',
          path: '/fields/Microsoft.VSTS.Common.Severity',
          from: '',
          value: '1 - Critical'
        }
      ]
      post_patch("#{@api_endpoint}/#{project[:id]}/_apis/wit/workitems/$Bug?api-version=5.0", content.to_json)
    end
  end

  def process_dependency(project, repo, dependabot_config)
    # not supported: target_branch, default_reviewers, default_assignees, default_labels, allowed_updates, version_requirement_updates

    package_manager = case dependabot_config['package_manager']
                      when 'javascript' then 'npm_and_yarn'
                      when 'ruby:bundler' then 'bundler'
                      when 'php:composer' then 'composer'
                      when 'python' then 'pip'
                      when 'go:modules' then 'go_modules'
                      when 'go:dep' then 'dep'
                      when 'java:maven' then 'maven'
                      when 'java:gradle' then 'gradle'
                      when 'dotnet:nuget' then 'nuget'
                      when 'rust:cargo' then 'cargo'
                      when 'elixir:hex' then 'hex'
                      when 'docker' then 'docker'
                      when 'terraform' then 'terraform'
                      when 'submodules' then 'submodules'
                      when 'elm' then 'elm'
                      else raise "Unsupported package manager: #{dependabot_config['package_manager']}"
    end

    directory = dependabot_config['directory']

    update_schedule = case dependabot_config['update_schedule']
                      when 'live' then true
                      when 'daily' then true
                      when 'weekly' then Date.today.strftime('%w').to_i == 1
                      when 'monthly' then Date.today.strftime('%e').to_i == 1
                      else raise "Unsupported update schedule: #{dependabot_config['update_schedule']}"
    end

    ignore_dependency_names = []
    ignored_updates = dependabot_config['ignored_updates']
    unless ignored_updates.nil?
      ignore_dependency_names = ignored_updates.map { |rule| rule['match']['dependency_name'] }

      # not supported: ignored_updates.match.version_requirement
    end

    automerged_dependency_names = []
    automerged_updates = dependabot_config['automerged_updates']
    unless automerged_updates.nil?
      automerged_dependency_names = automerged_updates.map { |rule| rule['match']['dependency_name'] }

      # not supported: automerged_updates.match.dependency_type, automerged_updates.match.update_type
    end

    if update_schedule == false
      puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => Skipping dependency checking"
    else
      puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => Dependabot configuration { directory: #{directory}, ignore: #{ignore_dependency_names}, automerged: #{automerged_dependency_names} }"
      project_repo_source = Dependabot::Source.new(
        provider: 'azure',
        repo: "#{@organisation}/#{project[:id]}/_git/#{repo[:id]}",
        directory: directory
      )

      puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => Fetching dependency files..."
      fetcher = Dependabot::FileFetchers.for_package_manager(package_manager).new(
        source: project_repo_source,
        credentials: @available_credentials
      )
      files = fetcher.files
      commit = fetcher.commit

      puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => Parsing dependencies information.."
      parser = Dependabot::FileParsers.for_package_manager(package_manager).new(
        dependency_files: files,
        source: project_repo_source,
        credentials: @available_credentials
      )

      dependencies = parser.parse
      dependencies.select(&:top_level?).each do |dep|
        if match_dependency?(dep.name, ignore_dependency_names)
          puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version}) => Dependency ignored"
          next
        end

        puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version}) => Checking for updates.."

        checker = Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
          dependency: dep,
          dependency_files: files,
          credentials: @available_credentials
        )

        # Check if the dependency is up to date.
        if checker.up_to_date?
          puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version}) => Already up to date"
          next
        end

        # Check if the dependency can be updated.
        requirements_to_unlock =
          if !checker.requirements_unlocked_or_can_be?
            if checker.can_update?(requirements_to_unlock: :none) then :none
            else :update_not_possible
            end
          elsif checker.can_update?(requirements_to_unlock: :own) then :own
          elsif checker.can_update?(requirements_to_unlock: :all) then :all
          else :update_not_possible
            end
        if requirements_to_unlock == :update_not_possible
          puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version}) => Cannot be updated"
          next
        end

        updated_deps = checker.updated_dependencies(
          requirements_to_unlock: requirements_to_unlock
        )
        puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version} -> #{updated_deps.first.version}) => Generating file updates..."
        updater = Dependabot::FileUpdaters.for_package_manager(package_manager).new(
          dependencies: updated_deps,
          dependency_files: files,
          credentials: @available_credentials
        )
        updated_files = updater.updated_dependency_files

        puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version} -> #{updated_deps.first.version}) => Creating pull request..."
        pr_creator = Dependabot::PullRequestCreator.new(
          source: project_repo_source,
          base_commit: commit,
          dependencies: updated_deps,
          files: updated_files,
          credentials: @available_credentials,
          label_language: true
        )
        pull_request = pr_creator.create

        unless pull_request
          puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version} -> #{updated_deps.first.version}) => Pull request already exists"
          next
        end

        pull_request_details = JSON.parse(pull_request.body)
        pull_request_id = pull_request_details.fetch('pullRequestId')
        puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version} -> #{updated_deps.first.version}) => Pull request created (#{pull_request_id})"

        next unless match_dependency?(dep.name, automerged_dependency_names)

        creator_id = pull_request_details.fetch('createdBy').fetch('id')

        puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version}) => Setting pull request to auto-complete by #{creator_id}..."
        content = {
          autoCompleteSetBy: {
            id: creator_id
          },
          completionOptions: {
            deleteSourceBranch: 'true'
          }
        }
        patch("#{@api_endpoint}/#{project[:id]}/_apis/git/repositories/#{repo[:id]}/pullrequests/#{pull_request_id}?api-version=5.0", content.to_json)

        puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => #{package_manager} => #{dep.name} (#{dep.version}) => Adding automatic approval by #{creator_id}..."
        content = { vote: 10 }
        put("#{@api_endpoint}/#{project[:id]}/_apis/git/repositories/#{repo[:id]}/pullrequests/#{pull_request_id}/reviewers/#{creator_id}?api-version=5.0", content.to_json)
      end
    end
  rescue StandardError => e
    puts "#{@organisation} => #{project[:name]} => #{repo[:name]} => Failed processing: #{e.message}"
  end

  def match_dependency?(dep_name, dependency_name_matches)
    match = dependency_name_matches.include? dep_name

    if match == false
      match = dependency_name_matches
              .select { |dependency_name_match| dependency_name_match.end_with? '*' }
              .map { |dependency_name_match| dependency_name_match[0...-1] }
              .map { |dependency_name_match| dep_name.start_with? dependency_name_match }
              .any?
    end

    match
  end

  #############

  def get(url)
    # puts "get -> #{url}"

    response = Excon.get(
      url,
      user: @organisation_credentials&.fetch('username'),
      password: @organisation_credentials&.fetch('password'),
      idempotent: true,
      **Dependabot::SharedHelpers.excon_defaults
    )
    raise Unathorized if response.status == 401
    raise NotFound if response.status == 404

    # puts " -> (#{response.status}) #{response.body}"

    response
  end

  def post(url, json)
    # puts "post -> #{url}"

    response = Excon.post(
      url,
      headers: {
        'Content-Type' => 'application/json'
      },
      body: json,
      user: @organisation_credentials&.fetch('username'),
      password: @organisation_credentials&.fetch('password'),
      idempotent: true,
      **Dependabot::SharedHelpers.excon_defaults
    )
    raise Unathorized if response.status == 401
    raise NotFound if response.status == 404

    # puts " -> (#{response.status}) #{response.body}"

    response
  end

  def post_patch(url, json)
    # puts "post_patch -> #{url}"

    response = Excon.post(
      url,
      headers: {
        'Content-Type' => 'application/json-patch+json'
      },
      body: json,
      user: @organisation_credentials&.fetch('username'),
      password: @organisation_credentials&.fetch('password'),
      idempotent: true,
      **Dependabot::SharedHelpers.excon_defaults
    )
    raise Unathorized if response.status == 401
    raise NotFound if response.status == 404

    # puts " -> (#{response.status}) #{response.body}"

    response
  end

  def patch(url, json)
    # puts "patch -> #{url}"

    response = Excon.patch(
      url,
      headers: {
        'Content-Type' => 'application/json'
      },
      body: json,
      user: @organisation_credentials&.fetch('username'),
      password: @organisation_credentials&.fetch('password'),
      idempotent: true,
      **Dependabot::SharedHelpers.excon_defaults
    )
    raise Unathorized if response.status == 401
    raise NotFound if response.status == 404

    # puts " -> (#{response.status}) #{response.body}"

    response
  end

  def put(url, json)
    # puts "put -> #{url}"

    response = Excon.put(
      url,
      headers: {
        'Content-Type' => 'application/json'
      },
      body: json,
      user: @organisation_credentials&.fetch('username'),
      password: @organisation_credentials&.fetch('password'),
      idempotent: true,
      **Dependabot::SharedHelpers.excon_defaults
    )
    raise Unathorized if response.status == 401
    raise NotFound if response.status == 404

    # puts " -> (#{response.status}) #{response.body}"

    response
  end
end
