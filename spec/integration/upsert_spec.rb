require 'spec_helper'
require 'promiscuous/worker'

describe Promiscuous do
  before { load_models }

  before do
    define_constant('Publisher', Promiscuous::Publisher::Mongoid) do
      publish :to => 'crowdtap/publisher_model',
              :class => PublisherModel,
              :attributes => [:field_1, :field_2, :field_3]
    end

    define_constant('Subscriber', Promiscuous::Subscriber::Mongoid) do
      subscribe :from => 'crowdtap/publisher_model',
                :class => SubscriberModel,
                :upsert => true,
                :attributes => [:field_1, :field_2, :field_3]
    end
  end

  context 'when updating' do
    it 'replicates' do
      use_fake_amqp
      pub = PublisherModel.create(:field_1 => '1', :field_2 => '2', :field_3 => '3')
      use_real_amqp(:logger_level => Logger::FATAL)

      Promiscuous::Worker.run

      pub.update_attributes(:field_1 => '1_updated', :field_2 => '2_updated')

      eventually do
        sub = SubscriberModel.first
        sub.id.should == pub.id
        sub.field_1.should == pub.field_1
        sub.field_2.should == pub.field_2
        sub.field_3.should == pub.field_3
      end
    end
  end

  context 'when destroying' do
    it 'replicates' do
      use_fake_amqp(:logger_level => Logger::FATAL)
      pub1 = PublisherModel.create(:field_1 => '1', :field_2 => '2', :field_3 => '3')
      use_real_amqp(:logger_level => Logger::FATAL)

      Promiscuous::Worker.run

      pub2 = PublisherModel.create(:field_1 => 'a', :field_2 => 'b', :field_3 => 'c')
      pub1.destroy

      eventually do
        SubscriberModel.where(:_id => pub1.id).count.should == 0
        SubscriberModel.where(:_id => pub2.id).count.should == 1
      end
    end
  end

  after do
    Promiscuous::AMQP.close
    Promiscuous::Subscriber::AMQP.subscribers.clear
  end
end
