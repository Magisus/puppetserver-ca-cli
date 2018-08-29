require 'spec_helper'
require 'utils/ssl'

require 'tmpdir'

require 'puppetserver/ca/action/create'
require 'puppetserver/ca/logger'
require 'puppetserver/ca/utils/http_client'

RSpec.describe Puppetserver::Ca::Action::Create do
  include Utils::SSL

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:logger) { Puppetserver::Ca::Logger.new(:info, stdout, stderr) }

  subject { Puppetserver::Ca::Action::Create.new(logger) }

  describe 'flags' do
    it 'takes a single certname' do
      result, maybe_code = subject.parse(['--certname', 'foo.example.com'])
      expect(maybe_code).to eq(nil)
      expect(result['certnames']).to eq(['foo.example.com'])
    end

    it 'takes a comma separated list of certnames' do
      result, maybe_code = subject.parse(['--certname', 'foo,bar'])
      expect(maybe_code).to eq(nil)
      expect(result['certnames']).to eq(['foo', 'bar'])
    end

    it 'takes a custom puppet.conf location' do
      result, maybe_code = subject.parse(['--certname', 'foo',
                                          '--config', '/dev/tcp/example.com'])
      expect(maybe_code).to be(nil)
      expect(result['config']).to eq('/dev/tcp/example.com')
    end
  end

  describe 'validation' do
    it 'prints the help output & returns 1 if invalid flags are given' do
      _, code = subject.parse(['--hello', '--certname', "amy.net"])
      expect(code).to eq(1)
      expect(stderr.string).to match(/Error.*--hello/m)
    end

    it 'requires at least one certname' do
      _, code = subject.parse([])
      expect(code).to eq(1)
      expect(stderr.string).to include('one certname is required')
    end

    it 'cannot create certs with the names of flags' do
      result, code = subject.parse(['--certname', '--config'])
      expect(code).to eq(1)
      expect(stderr.string).to include('Cannot manage cert named `--config`')
      expect(result['certnames']).to eq(['--config'])
    end

    it 'requires certnames to be in all lowercase characters' do
      _, code = subject.parse(['--certname', 'uPperCase.net'])
      expect(code).to eq(1)
      expect(stderr.string).to include('Certificate names must be lower case')
    end
  end

  describe 'downloading' do
    Result = Struct.new(:code, :body)

    let(:success) { Result.new('204', '') }
    let(:success_with_content) { Result.new('200', 'some cert') }
    let(:connection) { double }

    before do
      allow_any_instance_of(Puppetserver::Ca::Utils::HttpClient).
        to receive(:with_connection).and_yield(connection)
      allow_any_instance_of(Puppetserver::Ca::Utils::HttpClient).
        to receive(:make_store)
      allow_any_instance_of(Puppetserver::Ca::Utils::HttpClient).
        to receive(:load_cert)
      allow_any_instance_of(Puppetserver::Ca::Utils::HttpClient).
        to receive(:load_key)
    end

    it 'logs success and returns zero if downloaded' do
      allow(connection).to receive(:put).and_return(success)
      allow(connection).to receive(:get).and_return(success_with_content)
      Dir.mktmpdir do |tmpdir|
        with_temp_dirs tmpdir do |config|
          code = subject.run({'certnames' => ['foo'],
                              'config' => config,
                              'subject-alt-names' => ''})
          expect(code).to eq(0)
          expect(stdout.string.chomp).to include('Successfully saved certificate for foo')
          expect(stderr.string).to be_empty
        end
      end
    end

    it 'logs an error if any could not be downloaded' do
      not_found = Result.new('404', 'Not Found')
      allow(connection).to receive(:put).and_return(success)
      allow(connection).to receive(:get).and_return(not_found, success_with_content)
      Dir.mktmpdir do |tmpdir|
        with_temp_dirs tmpdir do |config|
          code = subject.run({'certnames' => ['foo', 'bar'],
                              'config' => config,
                              'subject-alt-names' => ''})
          expect(code).to eq(1)
          expect(stdout.string.chomp).to include('Successfully saved certificate for bar')
          expect(stderr.string).to match(/Error.*foo.*not be found/m)
        end
      end
    end

    it 'prints an error if an unknown error occurs' do
      error = Result.new('500', 'Internal Server Error')
      allow(connection).to receive(:put).and_return(success)
      allow(connection).to receive(:get).and_return(error, success_with_content)
      Dir.mktmpdir do |tmpdir|
        with_temp_dirs tmpdir do |config|
          code = subject.run({'certnames' => ['foo', 'bar'],
                              'config' => config,
                              'subject-alt-names' => ''})
          expect(code).to eq(1)
          expect(stdout.string.chomp).to include('Successfully saved certificate for bar')
          expect(stderr.string).
            to match(/Error.*attempting to download.*code: 500.*body: Internal Server Error/m)
        end
      end
    end

    describe 'subject alternative names' do
      it 'accepts unprefixed alt names' do
        result, maybe_code = subject.parse(['--subject-alt-names', 'foo.com',
                                            '--certname', 'ulla.com'])
        expect(maybe_code).to eq(nil)
        expect(result['subject-alt-names']).to eq('foo.com')
      end

      it 'adds no attributes to csr if subject_alt_names is empty' do
        settings = { :subject_alt_names => "",
                     :keylength => 2098}
        _, csr = subject.generate_key_csr('foo', settings, OpenSSL::Digest::SHA256.new)
        expect(csr.attributes.count).to eq(0)
      end

      it 'adds an attribute to csr if subject_alt_names are present' do
        settings = { :subject_alt_names => "DNS:foo",
                     :keylength => 2098}
        _, csr = subject.generate_key_csr('foo', settings, OpenSSL::Digest::SHA256.new)
        expect(csr.attributes.count).to eq(1)
      end
    end
  end
end
