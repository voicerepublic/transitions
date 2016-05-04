module Transitions
  class Machine
    attr_writer :initial_state
    attr_accessor :states, :events, :state_index
    attr_reader :klass, :auto_scopes

    def initialize(klass, options = {}, &block)
      @klass = klass
      @states = []
      @state_index = {}
      @events = {}
      update(options, &block)
    end

    def initial_state
      @initial_state ||= (states.first ? states.first.name : nil)
    end

    def update(options = {}, &block)
      @initial_state = options[:initial] if options.key?(:initial)
      @auto_scopes = options[:auto_scopes]
      instance_eval(&block) if block
      include_scopes if @auto_scopes && ::Transitions.active_model_descendant?(klass)
      self
    end

    #
    # rubocop:disable Metrics/MethodLength
    #
    def fire_event(event, record, persist, *args)
      handle_state_exit_callback record
      if new_state = transition_to_new_state(record, event, *args)
        handle_state_enter_callback record, new_state
        handle_event_fired_callback record, new_state, event
        old_state = record.current_state
        record.update_current_state(new_state, persist)
        handle_event_success_callback record, event
        handle_event_succeeded_callback record, old_state, event
        return true
      else
        handle_event_failed_callback record, event
        return false
      end
    rescue => e
      raise e unless record.respond_to?(:event_failed)
      record.send(:event_failed, event)
      return false
    end

    def events_for(state)
      events = @events.values.select { |event| event.transitions_from_state?(state) }
      events.map!(&:name)
    end

    def current_state_variable
      # TODO: Refactor me away.
      :@current_state
    end

    private

    def handle_state_exit_callback(record)
      state_index[record.current_state].call_action(:exit, record)
    end

    def transition_to_new_state(record, event, *args)
      @events[event].fire(record, nil, *args)
    end

    def handle_state_enter_callback(record, new_state)
      state_index[new_state].call_action(:enter, record)
    end

    def handle_event_fired_callback(record, new_state, event)
      return unless record.respond_to?(:event_fired, true)
      record.send(:event_fired, record.current_state, new_state, event)
    end

    def handle_event_success_callback(record, event)
      @events[event].success.call(record) if @events[event].success
    end

    def handle_event_succeeded_callback(record, old_state, event)
      return unless record.respond_to?(:event_succeeded, true)
      record.send(:event_succeeded, old_state, record.current_state, event)
    end

    def handle_event_failed_callback(record, event)
      return unless record.respond_to?(:event_failed, true)
      record.send(:event_failed, event)
    end

    def state(name, options = {})
      return if @state_index.key?(name) # Just ignore duplicates
      state = State.new(name, machine: self)
      state.update options
      @state_index[name] = state
      @states << state
    end

    def event(name, options = {}, &block)
      (@events[name] ||= Event.new(self, name)).update(options, &block)
    end

    # :reek:TooManyStatements: { max_statements: 7 }
    def include_scopes
      @states.each do |state|
        state_name = state.name.to_s
        if @klass.respond_to?(state_name)
          fail InvalidMethodOverride,
               "Transitions: Can not define scope `#{state_name}` because there is already"\
               'an equally named method defined - either rename the existing method or the state.'
        end
        scope = @klass.instance_exec { -> { where(state_machine.attribute_name => state_name) } }
        @klass.scope state_name, scope
      end
    end
  end
end
