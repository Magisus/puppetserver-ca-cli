require 'spec_helper'
require 'utils/ssl'

require 'tmpdir'
require 'fileutils'

require 'puppetserver/ca/cli'
require 'puppetserver/ca/generate_action'
require 'puppetserver/ca/logger'
require 'puppetserver/utils/signing_digest'
require 'puppetserver/ca/host'

RSpec.describe Puppetserver::Ca::GenerateAction do
  include Utils::SSL

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:logger) { Puppetserver::Ca::Logger.new(:info, stdout, stderr) }
  let(:usage) { /.*Usage:.* puppetserver ca generate.*Display this generate specific help output.*/m }

  subject { Puppetserver::Ca::GenerateAction.new(logger) }

  it 'prints the help output & returns 1 if invalid flags are given' do
    exit_code = Puppetserver::Ca::Cli.run(['generate', '--hello'], stdout, stderr)
    expect(stderr.string).to match(/Error.*--hello/m)
    expect(stderr.string).to match(usage)
    expect(exit_code).to eq(1)
  end

  it 'does not print the help output if called correctly' do
    Dir.mktmpdir do |tmpdir|
      with_temp_dirs tmpdir do |conf|
        exit_code = Puppetserver::Ca::Cli.run(['generate', '--config', conf], stdout, stderr)
        expect(stderr.string).to be_empty
        expect(stdout.string.strip).to eq("Generation succeeded. Find your files in #{tmpdir}/ca")
        expect(exit_code).to eq(0)
      end
    end
  end

  it 'generates a bundle ca_crt file, ca_key, int_key, and ca_crl file' do
    Dir.mktmpdir do |tmpdir|
      with_temp_dirs tmpdir do |conf|
        exit_code = subject.run({ 'config' => conf, 'subject_alt_names' => '' })
        expect(exit_code).to eq(0)
        expect(File.exist?(File.join(tmpdir, 'ca', 'ca_crt.pem'))).to be true
        expect(File.exist?(File.join(tmpdir, 'ca', 'ca_key.pem'))).to be true
        expect(File.exist?(File.join(tmpdir, 'ca', 'root_key.pem'))).to be true
        expect(File.exist?(File.join(tmpdir, 'ca', 'ca_crl.pem'))).to be true
      end
    end
  end

  describe 'subject alternative names' do
    it 'accepts unprefixed alt names' do
      result, maybe_code = subject.parse(['--subject-alt-names', 'foo.com'])
      expect(maybe_code).to eq(nil)
      expect(result['subject_alt_names']).to eq('foo.com')
    end

    it 'accepts DNS and IP alt names' do
      result, maybe_code = subject.parse(['--subject-alt-names', 'DNS:foo.com,IP:123.456.789'])
      expect(maybe_code).to eq(nil)
      expect(result['subject_alt_names']).to eq('DNS:foo.com,IP:123.456.789')
    end

    it 'prepends "DNS" to unprefixed alt names' do
      expect(subject.munge_alt_names('foo.com,IP:123.456.789')).to eq('DNS:foo.com, IP:123.456.789')
    end

    it 'adds subject alt names to the intermediate CA cert' do
      digest = Puppetserver::Utils::SigningDigest.new.digest
      host = Puppetserver::Ca::Host.new(digest)
      valid_until = Time.now + 1000

      root_key = host.create_private_key(4096)
      root_cert = subject.self_signed_ca(root_key, "root", valid_until, digest)
      int_key = host.create_private_key(4096)
      int_csr = host.create_csr("int_ca", int_key)
      int_cert = subject.sign_intermediate(root_key, root_cert, int_csr, valid_until, digest, "DNS:bar.net, IP:123.123.0.1")
      expect(int_cert.extensions[4].to_s).to eq("subjectAltName = DNS:bar.net, IP Address:123.123.0.1")
    end

    it 'chooses the default alt names when none are configured' do
      facter = class_double(Facter).as_stubbed_const
      expect(facter).to receive(:value).with(:fqdn) { 'foo.bar.net' }
      expect(facter).to receive(:value).with(:domain) { 'bar.net' }
      sans = subject.choose_alt_names('', '')
      expect(sans).to eq('DNS:foo.bar.net, DNS:puppet, DNS:puppet.bar.net')
    end

    it 'prefers alt names from the CLI to those in settings' do
      sans = subject.choose_alt_names('foo.com', 'bar.net')
      expect(sans).to eq('DNS:foo.com')
    end

    it 'uses settings alt names when none are specified from the CLI' do
      sans = subject.choose_alt_names('', 'bar.net')
      expect(sans).to eq('DNS:bar.net')
    end
  end
end
