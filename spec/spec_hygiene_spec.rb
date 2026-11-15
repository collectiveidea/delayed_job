require 'helper'

# Classes defined in a spec file - even inside a describe block - are
# top-level constants that leak into every other spec, and specs loaded
# alone wouldn't have the ones defined elsewhere. Shared test jobs live in
# spec/sample_jobs.rb instead.
describe 'Spec files' do
  spec_dir = File.expand_path(__dir__)
  # Files that legitimately define classes: shared jobs, backends, models.
  allowed = %w[sample_jobs.rb helper.rb delayed/backend/test.rb processes/backend.rb processes/jobs.rb]
  # Upstream specs, predating this check.
  allowed += %w[active_job_adapter_spec.rb message_sending_spec.rb performable_mailer_spec.rb]
  allowed += Dir.glob('autoloaded/*.rb', :base => spec_dir)

  Dir.glob('**/*.rb', :base => spec_dir).reject { |path| allowed.include?(path) }.sort.each do |path|
    it "#{path} defines no classes" do
      classes = File.readlines(File.join(spec_dir, path)).grep(/^\s*class [A-Z]/)
      expect(classes).to be_empty, "move #{classes.map(&:strip).join(', ')} to spec/sample_jobs.rb"
    end
  end

  %w[BlockingJob GateJob NapJob StuckJob].each do |name|
    it "loads #{name} from spec/sample_jobs.rb" do
      expect(Object.const_source_location(name).first).to eq File.join(spec_dir, 'sample_jobs.rb')
    end
  end

  it 'serializes and runs the moved jobs as before' do
    job = Delayed::Job.new(:payload_object => StuckJob.new(0, 3))
    expect(job.payload_object).to be_a StuckJob
    expect(job.max_run_time).to eq 3
    expect(YAML.load_dj(job.handler).seconds).to eq 0
  end
end
