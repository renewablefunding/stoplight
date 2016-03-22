# coding: utf-8

require 'spec_helper'
require 'stringio'

RSpec.describe Stoplight::Light::Runnable do
  subject { Stoplight::Light.new(name, &code) }

  let(:code) { -> { code_result } }
  let(:code_result) { random_string }
  let(:fallback) { -> (_) { fallback_result } }
  let(:fallback_result) { random_string }
  let(:name) { random_string }

  let(:failure) do
    Stoplight::Failure.new(error.class.name, error.message, time)
  end
  let(:error) { error_class.new(error_message) }
  let(:error_class) { Class.new(StandardError) }
  let(:error_message) { random_string }
  let(:time) { Time.new }

  def random_string
    ('a'..'z').to_a.sample(8).join
  end

  describe '#color' do
    it 'is initially green' do
      expect(subject.color).to eql(Stoplight::Color::GREEN)
    end

    it 'is green when locked green' do
      subject.data_store.set_state(subject, Stoplight::State::LOCKED_GREEN)
      expect(subject.color).to eql(Stoplight::Color::GREEN)
    end

    it 'is red when locked red' do
      subject.data_store.set_state(subject, Stoplight::State::LOCKED_RED)
      expect(subject.color).to eql(Stoplight::Color::RED)
    end

    it 'is red when there are many failures' do
      subject.threshold.times do
        subject.data_store.record_failure(subject, failure)
      end
      expect(subject.color).to eql(Stoplight::Color::RED)
    end

    it 'is yellow when the most recent failure is old' do
      (subject.threshold - 1).times do
        subject.data_store.record_failure(subject, failure)
      end
      other = Stoplight::Failure.new(
        error.class.name, error.message, Time.new - subject.timeout)
      subject.data_store.record_failure(subject, other)
      expect(subject.color).to eql(Stoplight::Color::YELLOW)
    end

    it 'is red when the least recent failure is old' do
      other = Stoplight::Failure.new(
        error.class.name, error.message, Time.new - subject.timeout)
      subject.data_store.record_failure(subject, other)
      (subject.threshold - 1).times do
        subject.data_store.record_failure(subject, failure)
      end
      expect(subject.color).to eql(Stoplight::Color::RED)
    end
  end

  describe '#run' do
    let(:notifiers) { [notifier] }
    let(:notifier) { Stoplight::Notifier::IO.new(io) }
    let(:io) { StringIO.new }

    before { subject.with_notifiers(notifiers) }

    context 'when the light is green' do
      before { subject.data_store.clear_failures(subject) }

      it 'runs the code' do
        expect(subject.run).to eql(code_result)
      end

      context 'with some failures' do
        before { subject.data_store.record_failure(subject, failure) }

        it 'clears the failures' do
          subject.run
          expect(subject.data_store.get_failures(subject).size).to eql(0)
        end
      end

      context 'when the code is failing' do
        let(:code_result) { raise error }

        it 're-raises the error' do
          expect { subject.run }.to raise_error(error.class)
        end

        it 'records the failure' do
          expect(subject.data_store.get_failures(subject).size).to eql(0)
          begin
            subject.run
          rescue error.class
            nil
          end
          expect(subject.data_store.get_failures(subject).size).to eql(1)
        end

        it 'notifies when transitioning to red' do
          subject.threshold.times do
            expect(io.string).to eql('')
            begin
              subject.run
            rescue error.class
              nil
            end
          end
          expect(io.string).to_not eql('')
        end

        context 'when the error is whitelisted' do
          let(:whitelisted_errors) { [error.class] }

          before { subject.with_whitelisted_errors(whitelisted_errors) }

          it 'does not record the failure' do
            expect(subject.data_store.get_failures(subject).size).to eql(0)
            begin
              subject.run
            rescue error.class
              nil
            end
            expect(subject.data_store.get_failures(subject).size).to eql(0)
          end
        end

        context 'when the error is blacklisted' do
          let(:blacklisted_errors) { [error.class] }

          before { subject.with_blacklisted_errors(blacklisted_errors) }

          it 'records the failure' do
            expect(subject.data_store.get_failures(subject).size).to eql(0)
            begin
              subject.run
            rescue error.class
              nil
            end
            expect(subject.data_store.get_failures(subject).size).to eql(1)
          end
        end

        context 'when the error is a blacklisted of Exception class' do
          let(:error_class) { Class.new(Exception) }
          let(:blacklisted_errors) { [error.class] }

          before { subject.with_blacklisted_errors(blacklisted_errors) }

          it 'records the failure' do
            expect(subject.data_store.get_failures(subject).size).to eql(0)
            begin
              subject.run
            rescue error.class
              nil
            end
            expect(subject.data_store.get_failures(subject).size).to eql(1)
          end
        end

        context 'when the error is not blacklisted' do
          let(:blacklisted_errors) { [RuntimeError] }

          before { subject.with_blacklisted_errors(blacklisted_errors) }

          it 'does not record the failure' do
            expect(subject.data_store.get_failures(subject).size).to eql(0)
            begin
              subject.run
            rescue error.class
              nil
            end
            expect(subject.data_store.get_failures(subject).size).to eql(0)
          end
        end

        context 'when the list of blacklisted errors is empty' do
          let(:blacklisted_errors) { [] }

          before { subject.with_blacklisted_errors(blacklisted_errors) }

          it 'records the failure' do
            expect(subject.data_store.get_failures(subject).size).to eql(0)
            begin
              subject.run
            rescue error.class
              nil
            end
            expect(subject.data_store.get_failures(subject).size).to eql(1)
          end
        end

        context 'when the error is both whitelisted and blacklisted' do
          let(:whitelisted_errors) { [error.class] }
          let(:blacklisted_errors) { [error.class] }

          before do
            subject
              .with_whitelisted_errors(whitelisted_errors)
              .with_blacklisted_errors(blacklisted_errors)
          end

          it 'does not record the failure' do
            expect(subject.data_store.get_failures(subject).size).to eql(0)
            begin
              subject.run
            rescue error.class
              nil
            end
            expect(subject.data_store.get_failures(subject).size).to eql(0)
          end
        end

        context 'with a fallback' do
          before { subject.with_fallback(&fallback) }

          it 'runs the fallback' do
            expect(subject.run).to eql(fallback_result)
          end

          it 'passes the error to the fallback' do
            subject.with_fallback do |e|
              expect(e).to eql(error)
              fallback_result
            end
            expect(subject.run).to eql(fallback_result)
          end
        end
      end

      context 'when the data store is failing' do
        let(:data_store) { Object.new }
        let(:error_notifier) { -> (_) {} }

        before do
          subject
            .with_data_store(data_store)
            .with_error_notifier(&error_notifier)
        end

        it 'runs the code' do
          expect(subject.run).to eql(code_result)
        end

        it 'notifies about the error' do
          has_notified = false
          subject.with_error_notifier do |e|
            has_notified = true
            expect(e).to be_a(NoMethodError)
          end
          subject.run
          expect(has_notified).to eql(true)
        end
      end
    end

    context 'when the light is yellow' do
      before do
        (subject.threshold - 1).times do
          subject.data_store.record_failure(subject, failure)
        end

        other = Stoplight::Failure.new(
          error.class.name, error.message, time - subject.timeout)
        subject.data_store.record_failure(subject, other)
      end

      it 'runs the code' do
        expect(subject.run).to eql(code_result)
      end

      it 'notifies when transitioning to green' do
        expect(io.string).to eql('')
        subject.run
        expect(io.string).to_not eql('')
      end
    end

    context 'when the light is red' do
      before do
        subject.threshold.times do
          subject.data_store.record_failure(subject, failure)
        end
      end

      it 'raises an error' do
        expect { subject.run }.to raise_error(Stoplight::Error::RedLight)
      end

      it 'uses the name as the error message' do
        e =
          begin
            subject.run
          rescue Stoplight::Error::RedLight => e
            e
          end
        expect(e.message).to eql(subject.name)
      end

      context 'with a fallback' do
        before { subject.with_fallback(&fallback) }

        it 'runs the fallback' do
          expect(subject.run).to eql(fallback_result)
        end

        it 'does not pass anything to the fallback' do
          subject.with_fallback do |e|
            expect(e).to eql(nil)
            fallback_result
          end
          expect(subject.run).to eql(fallback_result)
        end
      end
    end
  end
end
