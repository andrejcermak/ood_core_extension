require "ood_core/refinements/hash_extensions"
require "json"
  

# Utility class for the Coder adapter to interact with the Coders API.
class OodCore::Job::Adapters::Coder::Batch
  require_relative "coder_job_info"
  class Error < StandardError; end
  def initialize(config, credentials)
    @host = config[:host]
    @token = config[:token]
    @service_user = config[:service_user]
    @deletion_max_attempts = config[:deletion_max_attempts] || 5
    @deletion_timeout_interval_seconds = config[:deletion_timeout_interval] || 10
    @credentials = credentials 
  end

  def get_rich_parameters(coder_parameters, project_id, app_credentials)
    rich_parameter_values = [
      { name: "application_credential_name", value: app_credentials[:name] },
      { name: "application_credential_id", value: app_credentials[:id] },
      { name: "application_credential_secret", value: app_credentials[:secret] },
      {name: "project_id", value: project_id }
    ]
    if coder_parameters
      coder_parameters.each do |key, value|
        rich_parameter_values << { name: key, value: value.to_s}
      end
    end
    rich_parameter_values
  end

  def get_headers(coder_token)
    {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
      'Coder-Session-Token' => coder_token
    }
  end

  def submit(script)
    org_id = script.native[:org_id]
    project_id = script.native[:project_id]
    coder_parameters = script.native[:coder_parameters]
    endpoint = "#{@host}/api/v2/organizations/#{org_id}/members/#{@service_user}/workspaces"
    app_credentials = @credentials.generate_credentials(project_id)
    headers = get_headers(@token)
    workspace_name = "#{username}-#{script.native[:workspace_name]}-#{rand(2_821_109_907_456).to_s(36)}"
    body = {
      template_version_id: script.native[:template_version_id],
      name: workspace_name,
      rich_parameter_values: get_rich_parameters(coder_parameters, project_id, app_credentials),
    }

    resp = api_call('post', endpoint, headers, body)
    @credentials.save_credentials(resp["id"], app_credentials)
    resp["id"]

  end

  def delete(id)
    endpoint = "#{@host}/api/v2/workspaces/#{id}/builds"
    headers = get_headers(@token)
    body = {
      'orphan' => false,
      'transition' => 'delete'
    }
    api_call('post', endpoint, headers, body)
  
    credentials = @credentials.load_credentials(id)
    puts "credentials loaded #{credentials["id"]}" 
    wait_for_workspace_deletion(id) do |attempt|
      puts "#{Time.now.inspect} Deleting workspace (attempt #{attempt}/#{5})"
    end
  
    @credentials.destroy_credentials(credentials, workspace_json(id).dig("latest_build", "status"), id)
  end
  
  def wait_for_workspace_deletion(id)
    max_attempts = @deletion_max_attempts
    timeout_interval = @deletion_timeout_interval_seconds
  
    max_attempts.times do |attempt|
      break unless workspace_json(id) && workspace_json(id).dig("latest_build", "status") == "deleting"
      yield(attempt + 1)
      sleep(timeout_interval)
    end
  end

  def extract_error_messages(logs_array)    
    logs_array
    .reject { |n| n["output"].to_s.empty?}
    .map { |n| n["output"].scan(/"message":\s*"([^"]+)"/) }
    .reject {|n| n.empty?}
  end

  def workspace_json(id)
    endpoint = "#{@host}/api/v2/workspaces/#{id}?include_deleted=true"
    headers = get_headers(@token)
    api_call('get', endpoint, headers)
  end

  def info(id)
    workspace_info_from_json(workspace_json(id))
  end

  def coder_state_to_ood_status(coder_state)
    case coder_state
    when "starting"
      "queued"
    when "failed"
      "suspended"
    when "running"
      "running"
    when "deleted"
      "completed"
    when "stopped"
      "completed"
    else
      "undetermined"
    end
  end
  def build_logs(build_id)
    endpoint = "#{@host}/api/v2/workspacebuilds/#{build_id}/logs"
    headers = get_headers(@token)
    api_call('get', endpoint, headers)
  end
  def build_coder_job_info(json_data, status)
    coder_output_metadata = json_data["latest_build"]["resources"]
    &.find { |resource| resource["name"] == "coder_output" }
    &.dig("metadata")
    coder_output_hash = coder_output_metadata&.map { |meta| [meta["key"].to_sym, meta["value"]] }&.to_h || {}
    build_logs = build_logs(json_data["latest_build"]["id"])
    error_logs = extract_error_messages(build_logs)
    OodCore::Job::Adapters::Coder::CoderJobInfo.new(**{
      id: json_data["id"],
      job_name: json_data["workspace_name"],
      status: OodCore::Job::Status.new(state: status),
      job_owner: json_data["workspace_owner_name"],
      submission_time: json_data["created_at"],
      dispatch_time: json_data.dig("updated_at"),
      wallclock_time: wallclock_time(json_data, status),
      ood_connection_info: { host: coder_output_hash[:floating_ip], port: 80, error_logs: error_logs},
      native: coder_output_hash
  })
  end

  def wallclock_time(json_data, status)
    start_time = start_time(json_data) 
    end_time = end_time(json_data, status)
    end_time - start_time
  end  

  def start_time(json_data)
    start_time_string = json_data.dig("updated_at")
    DateTime.parse(start_time_string).to_time.to_i
  end 
 
  def end_time(json_data, status)
    if status == 'deleted'
      end_time_string = json_data["latest_build"].dig("updated_at") 
      et = DateTime.parse(end_time_string).to_time.to_i
    else
      et = DateTime.now.to_time.to_i
    end
    et
  end

  def workspace_info_from_json(json_data)
    state = json_data.dig("latest_build", "status") || json_data.dig("latest_build", "job", "status")
    status = coder_state_to_ood_status(state)
    build_coder_job_info(json_data, status)
  end

  def api_call(method, endpoint, headers, body = nil)
    uri = URI(endpoint)
    case method.downcase
    when 'get'
      request = Net::HTTP::Get.new(uri, headers)
    when 'post'
      request = Net::HTTP::Post.new(uri, headers)
    when 'delete'
      request = Net::HTTP::Delete.new(uri, headers)
    else
      raise ArgumentError, "Invalid HTTP method: #{method}"
    end

    request.body = body.to_json if body
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end
    case response
    when Net::HTTPSuccess
      JSON.parse(response.body)
    else
      raise Error, "HTTP Error: #{response.code} #{response.message}  for request #{endpoint} and body #{body}"
    end
  end

  def username
    @username ||= Etc.getlogin
  end

end
[{"id"=>100670, "created_at"=>"2026-02-06T10:52:12.175Z", "log_source"=>"provisioner_daemon", "log_level"=>"info", "stage"=>"Setting up", "output"=>""}, {"id"=>100671, "created_at"=>"2026-02-06T10:52:12.23Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"Initializing the backend..."}, {"id"=>100672, "created_at"=>"2026-02-06T10:52:12.232Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"Initializing provider plugins..."}, {"id"=>100673, "created_at"=>"2026-02-06T10:52:12.232Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"- Reusing previous version of terraform-provider-openstack/openstack from the dependency lock file"}, {"id"=>100674, "created_at"=>"2026-02-06T10:52:12.284Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"- Reusing previous version of coder/coder from the dependency lock file"}, {"id"=>100675, "created_at"=>"2026-02-06T10:52:12.435Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"- Reusing previous version of hashicorp/null from the dependency lock file"}, {"id"=>100676, "created_at"=>"2026-02-06T10:52:12.519Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"- Using terraform-provider-openstack/openstack v3.1.0 from the shared cache directory"}, {"id"=>100677, "created_at"=>"2026-02-06T10:52:12.707Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"- Using coder/coder v1.0.4 from the shared cache directory"}, {"id"=>100678, "created_at"=>"2026-02-06T10:52:12.84Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"- Using hashicorp/null v3.2.4 from the shared cache directory"}, {"id"=>100679, "created_at"=>"2026-02-06T10:52:12.925Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"OpenTofu has been successfully initialized!"}, {"id"=>100680, "created_at"=>"2026-02-06T10:52:12.925Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"You may now begin working with OpenTofu. Try running \"tofu plan\" to see"}, {"id"=>100681, "created_at"=>"2026-02-06T10:52:12.925Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"any changes that are required for your infrastructure. All OpenTofu commands"}, {"id"=>100682, "created_at"=>"2026-02-06T10:52:12.925Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"should now work."}, {"id"=>100683, "created_at"=>"2026-02-06T10:52:12.925Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"If you ever set or change modules or backend configuration for OpenTofu,"}, {"id"=>100684, "created_at"=>"2026-02-06T10:52:12.925Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"rerun this command to reinitialize your working directory. If you forget, other"}, {"id"=>100685, "created_at"=>"2026-02-06T10:52:12.925Z", "log_source"=>"provisioner", "log_level"=>"debug", "stage"=>"Planning infrastructure", "output"=>"commands will detect it and remind you to do so if necessary."}, {"id"=>100686, "created_at"=>"2026-02-06T10:52:12.954Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"OpenTofu 1.9.1"}, {"id"=>100687, "created_at"=>"2026-02-06T10:52:13.343Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_workspace.me: Refreshing..."}, {"id"=>100688, "created_at"=>"2026-02-06T10:52:13.343Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.openstack_identity_provider: Refreshing..."}, {"id"=>100689, "created_at"=>"2026-02-06T10:52:13.343Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.application_credential_id: Refreshing..."}, {"id"=>100690, "created_at"=>"2026-02-06T10:52:13.343Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.application_credential_secret: Refreshing..."}, {"id"=>100691, "created_at"=>"2026-02-06T10:52:13.344Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.application_credential_secret: Refresh complete after 0s [id=6f6fa66a-473e-4f98-b881-0a82e8ce4f15]"}, {"id"=>100692, "created_at"=>"2026-02-06T10:52:13.345Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.project_id: Refreshing..."}, {"id"=>100693, "created_at"=>"2026-02-06T10:52:13.345Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.application_credential_id: Refresh complete after 0s [id=7841e6e8-be51-4183-b663-a81c928ab8ab]"}, {"id"=>100694, "created_at"=>"2026-02-06T10:52:13.345Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.openstack_region: Refreshing..."}, {"id"=>100695, "created_at"=>"2026-02-06T10:52:13.345Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_workspace.me: Refresh complete after 0s [id=ce56a408-1008-44f0-bc44-44843b8f764d]"}, {"id"=>100696, "created_at"=>"2026-02-06T10:52:13.346Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.openstack_identity_provider: Refresh complete after 0s [id=5d5b829d-314a-4096-b9d2-f432198006f4]"}, {"id"=>100697, "created_at"=>"2026-02-06T10:52:13.346Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.application_credential_name: Refreshing..."}, {"id"=>100698, "created_at"=>"2026-02-06T10:52:13.349Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.flavor: Refreshing..."}, {"id"=>100699, "created_at"=>"2026-02-06T10:52:13.349Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.pubkey: Refreshing..."}, {"id"=>100700, "created_at"=>"2026-02-06T10:52:13.349Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.project_id: Refresh complete after 0s [id=26e224cd-77d4-482a-9913-a8a57508f2aa]"}, {"id"=>100701, "created_at"=>"2026-02-06T10:52:13.349Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.flavor: Refresh complete after 0s [id=ccb08f91-dffb-47ff-9962-d43a476455de]"}, {"id"=>100702, "created_at"=>"2026-02-06T10:52:13.349Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.openstack_region: Refresh complete after 0s [id=805c5f68-fa53-4a8a-85d7-48efa1822989]"}, {"id"=>100703, "created_at"=>"2026-02-06T10:52:13.349Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.pubkey: Refresh complete after 0s [id=01bc11a6-f897-46ea-bbdd-2ff0ac1a25dc]"}, {"id"=>100704, "created_at"=>"2026-02-06T10:52:13.35Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.coder_parameter.application_credential_name: Refresh complete after 0s [id=c54c5c11-f817-497e-b02b-19b078a85095]"}, {"id"=>100705, "created_at"=>"2026-02-06T10:52:13.382Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.openstack_networking_network_v2.external_network: Refreshing..."}, {"id"=>100706, "created_at"=>"2026-02-06T10:52:13.382Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.openstack_networking_network_v2.network_default: Refreshing..."}, {"id"=>100707, "created_at"=>"2026-02-06T10:52:14.536Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.openstack_networking_network_v2.network_default: Refresh complete after 2s [id=21af501a-69a3-4f90-8b40-a6ffd52b36c0]"}, {"id"=>100708, "created_at"=>"2026-02-06T10:52:14.655Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"data.openstack_networking_network_v2.external_network: Refresh complete after 2s [id=95e346fd-a52f-4498-84aa-23f2da323429]"}, {"id"=>100709, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"openstack_networking_secgroup_v2.ood_security_group: Plan to create"}, {"id"=>100710, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"openstack_compute_keypair_v2.pubkey: Plan to create"}, {"id"=>100711, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"openstack_networking_floatingip_v2.vip_fip: Plan to create"}, {"id"=>100712, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"openstack_networking_secgroup_rule_v2.shh_rule: Plan to create"}, {"id"=>100713, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"openstack_networking_port_v2.port: Plan to create"}, {"id"=>100714, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"openstack_networking_floatingip_associate_v2.res_vip_fip_associate: Plan to create"}, {"id"=>100715, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"openstack_compute_instance_v2.ubuntu_from_ondemand: Plan to create"}, {"id"=>100716, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"null_resource.coder_output: Plan to create"}, {"id"=>100717, "created_at"=>"2026-02-06T10:52:14.662Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"coder_metadata.floating_ip: Plan to create"}, {"id"=>100718, "created_at"=>"2026-02-06T10:52:14.663Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Planning infrastructure", "output"=>"Plan: 9 to add, 0 to change, 0 to destroy."}, {"id"=>100719, "created_at"=>"2026-02-06T10:52:15.275Z", "log_source"=>"provisioner_daemon", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>""}, {"id"=>100720, "created_at"=>"2026-02-06T10:52:15.327Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"OpenTofu 1.9.1"}, {"id"=>100721, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_secgroup_v2.ood_security_group: Plan to create"}, {"id"=>100722, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_compute_keypair_v2.pubkey: Plan to create"}, {"id"=>100723, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_floatingip_v2.vip_fip: Plan to create"}, {"id"=>100724, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_secgroup_rule_v2.shh_rule: Plan to create"}, {"id"=>100725, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_port_v2.port: Plan to create"}, {"id"=>100726, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_floatingip_associate_v2.res_vip_fip_associate: Plan to create"}, {"id"=>100727, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_compute_instance_v2.ubuntu_from_ondemand: Plan to create"}, {"id"=>100728, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"null_resource.coder_output: Plan to create"}, {"id"=>100729, "created_at"=>"2026-02-06T10:52:15.59Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"coder_metadata.floating_ip: Plan to create"}, {"id"=>100730, "created_at"=>"2026-02-06T10:52:15.673Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_compute_keypair_v2.pubkey: Creating..."}, {"id"=>100731, "created_at"=>"2026-02-06T10:52:15.673Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_floatingip_v2.vip_fip: Creating..."}, {"id"=>100732, "created_at"=>"2026-02-06T10:52:15.674Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_secgroup_v2.ood_security_group: Creating..."}, {"id"=>100733, "created_at"=>"2026-02-06T10:52:16.861Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_compute_keypair_v2.pubkey: Creation complete after 1s [id=xcermak5-os-vm-zo9divhv-keypair]"}, {"id"=>100734, "created_at"=>"2026-02-06T10:52:16.993Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_floatingip_v2.vip_fip: Creation errored after 1s"}, {"id"=>100735, "created_at"=>"2026-02-06T10:52:17.137Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_secgroup_v2.ood_security_group: Creation complete after 1s [id=e4ae6605-431c-4fe0-9507-780ffcfc3b53]"}, {"id"=>100736, "created_at"=>"2026-02-06T10:52:17.14Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_secgroup_rule_v2.shh_rule: Creating..."}, {"id"=>100737, "created_at"=>"2026-02-06T10:52:17.143Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_port_v2.port: Creating..."}, {"id"=>100738, "created_at"=>"2026-02-06T10:52:17.24Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_secgroup_rule_v2.shh_rule: Creation complete after 0s [id=9292f68b-70c1-4527-b2d5-964a191a10c4]"}, {"id"=>100739, "created_at"=>"2026-02-06T10:52:23.349Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_networking_port_v2.port: Creation complete after 6s [id=40f9d79b-cdb1-40ae-a488-e2a7c56e9aad]"}, {"id"=>100740, "created_at"=>"2026-02-06T10:52:23.355Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_compute_instance_v2.ubuntu_from_ondemand: Creating..."}, {"id"=>100741, "created_at"=>"2026-02-06T10:52:24.492Z", "log_source"=>"provisioner", "log_level"=>"info", "stage"=>"Starting workspace", "output"=>"openstack_compute_instance_v2.ubuntu_from_ondemand: Creation errored after 1s"}, {"id"=>100742, "created_at"=>"2026-02-06T10:52:24.497Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>"Error: Error creating openstack_networking_floatingip_v2: Expected HTTP response code [201 202] when accessing [POST https://network.brno.openstack.cloud.e-infra.cz/v2.0/floatingips], but got 409 instead: {\"NeutronError\": {\"type\": \"OverQuota\", \"message\": \"Quota exceeded for resources: ['floatingip'].\", \"detail\": \"\"}}"}, {"id"=>100743, "created_at"=>"2026-02-06T10:52:24.497Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>"on main.tf line 59, in resource \"openstack_networking_floatingip_v2\" \"vip_fip\":"}, {"id"=>100744, "created_at"=>"2026-02-06T10:52:24.497Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>"  59: resource \"openstack_networking_floatingip_v2\" \"vip_fip\" {"}, {"id"=>100745, "created_at"=>"2026-02-06T10:52:24.497Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>""}, {"id"=>100746, "created_at"=>"2026-02-06T10:52:24.497Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>""}, {"id"=>100747, "created_at"=>"2026-02-06T10:52:24.497Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>"Error: Error creating OpenStack server: Expected HTTP response code [200 202] when accessing [POST https://compute.brno.openstack.cloud.e-infra.cz/v2.1/e495700ad00349bab1d6c75fa13d0ad1/servers], but got 403 instead: {\"forbidden\": {\"code\": 403, \"message\": \"Quota exceeded for ram: Requested 30720, but already used 38912 of 51200 ram\"}}"}, {"id"=>100748, "created_at"=>"2026-02-06T10:52:24.498Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>"on main.tf line 65, in resource \"openstack_compute_instance_v2\" \"ubuntu_from_ondemand\":"}, {"id"=>100749, "created_at"=>"2026-02-06T10:52:24.498Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>"  65: resource \"openstack_compute_instance_v2\" \"ubuntu_from_ondemand\" {"}, {"id"=>100750, "created_at"=>"2026-02-06T10:52:24.498Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>""}, {"id"=>100751, "created_at"=>"2026-02-06T10:52:24.498Z", "log_source"=>"provisioner", "log_level"=>"error", "stage"=>"Starting workspace", "output"=>""}, {"id"=>100752, "created_at"=>"2026-02-06T10:52:24.503Z", "log_source"=>"provisioner_daemon", "log_level"=>"info", "stage"=>"Cleaning Up", "output"=>""}]
