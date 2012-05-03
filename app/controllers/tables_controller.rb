# coding: UTF-8

# BillGastro -- The innovative Point Of Sales Software for your Restaurant
# Copyright (C) 2012-2013  Red (E) Tools LTD
# 
# See license.txt for the license applying to all files within this software.

class TablesController < ApplicationController

  def index
    @tables = @current_user.tables.existing
    @last_finished_order = Order.find_all_by_finished(true).last
    respond_to do |wants|
      wants.html
      wants.js
    end
  end

  def show
    @table = get_model
    @cost_centers = CostCenter.accessible_by(@current_user).existing
    @taxes = Tax.accessible_by(@current_user).existing

    @orders = Order.accessible_by(@current_user).where(:table_id => @table.id, :finished => false )
    if @orders.size > 1
      render 'orders/go_to_invoice_form'
    else
      @order = @orders.first
      render 'orders/go_to_order_form'
    end
  end

  def new
    @table = Table.new
  end

  def create
    @table = Table.new(params[:table])
    @table.vendor = @current_vendor
    @table.company = @current_company
    if @table.save
      @current_vendor.users.each do |u|
        u.tables << @table
      end
      redirect_to(tables_path)
    else
      render(:new)
    end
  end

  def edit
    @table = get_model
    render :new
  end

  def update
    @table = get_model
    success = @table.update_attributes(params[:table])
    respond_to do |wants|
      wants.html{ success ? redirect_to(tables_path) : render(:new)}
      wants.js { render :nothing => true }
    end
  end

  def destroy
    @table = get_model
    @table.update_attribute :hidden, true
    redirect_to tables_path
  end

  def time_range
    @from = Date.civil( params[:from][:year ].to_i,
                        params[:from][:month].to_i,
                        params[:from][:day  ].to_i) if params[:from]
    @to =   Date.civil( params[:to  ][:year ].to_i,
                        params[:to  ][:month].to_i,
                        params[:to  ][:day  ].to_i) if params[:to]
    @tables = Table.accessible_by(@current_user).existing
    render :index
  end

  def mobile
    @tables = @current_user.tables.existing
  end

end
